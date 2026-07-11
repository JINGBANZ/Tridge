import SwiftUI
import SwiftData

/// Edit one item: art, name, quantity, storage, expiry (typed, or scanned from
/// the printed label), plus the consume/delete actions.
struct ItemDetailSheet: View {
    @Bindable var item: FridgeItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9

    @State private var showArtPicker = false
    @State private var showDateCamera = false
    @State private var scannedDate: Date?
    @State private var showScanConfirm = false
    @State private var showScanFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Button {
                            showArtPicker = true
                        } label: {
                            Text(Artwork.artwork(for: item))
                                .font(.system(size: AppTheme.heroArtSize))
                                .shadow(color: AppTheme.artShadow.color,
                                        radius: AppTheme.artShadow.radius,
                                        y: AppTheme.artShadow.y)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Change art")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: nameBinding)
                    LabeledContent("Quantity") {
                        TextField("1", value: quantityBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Storage", selection: storageBinding) {
                        ForEach(StorageLocation.allCases, id: \.self) { location in
                            Text(location.label).tag(location)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    DatePicker("Expires", selection: expiryBinding, displayedComponents: .date)
                    Button {
                        showDateCamera = true
                    } label: {
                        Label("Scan date label", systemImage: "camera")
                    }
                } footer: {
                    Text(expiryFootnote)
                }

                Section {
                    Button("😋  Ate it") { consume(as: .eaten) }
                    Button("🗑️  Tossed it") { consume(as: .tossed) }
                    Button("Delete", role: .destructive) { deleteItem() }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showArtPicker) {
            ArtPicker(selection: Binding(get: { item.artKey },
                                         set: { item.artKey = $0 }))
        }
        .fullScreenCover(isPresented: $showDateCamera) {
            DocumentCameraView { image in
                showDateCamera = false
                guard let image else { return }
                Task {
                    if let date = await DateLabelScanner.scanDate(in: image) {
                        scannedDate = date
                        showScanConfirm = true
                    } else {
                        showScanFailed = true
                    }
                }
            }
            .ignoresSafeArea()
        }
        .alert("Use this date?", isPresented: $showScanConfirm, presenting: scannedDate) { date in
            Button("Use \(date.formatted(date: .abbreviated, time: .omitted))") {
                setExpiry(date, source: .scannedLabel)
            }
            Button("Cancel", role: .cancel) {}
        } message: { date in
            Text("The label reads \(date.formatted(date: .long, time: .omitted)).")
        }
        .alert("No date found", isPresented: $showScanFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't read a date from that label. Try getting closer.")
        }
    }

    // MARK: Bindings

    /// Renames go through `setName` so the merge/search key stays in sync.
    private var nameBinding: Binding<String> {
        Binding(get: { item.name }, set: { item.setName($0) })
    }

    private var storageBinding: Binding<StorageLocation> {
        Binding(get: { item.storage }, set: { item.storage = $0 })
    }

    /// Typed quantities are kept in the stepper's old 1...99 bounds.
    private var quantityBinding: Binding<Int> {
        Binding(get: { item.quantity },
                set: { item.quantity = min(max($0, 1), 99) })
    }

    /// Hand-edited dates become `.userSet` and reschedule both notifications.
    private var expiryBinding: Binding<Date> {
        Binding(get: { item.expiryDate },
                set: { setExpiry($0, source: .userSet) })
    }

    private func setExpiry(_ date: Date, source: ExpirySource) {
        item.expiryDate = date
        item.expirySource = source
        NotificationService.schedule(for: item, hour: notificationHour)
    }

    private var expiryFootnote: String {
        switch item.expirySource {
        case .llmEstimate: "Guessed by AI — tap to correct."
        case .userSet: "Set by you."
        case .scannedLabel: "Read from the printed label."
        }
    }

    // MARK: Actions

    private func consume(as status: ItemStatus) {
        Haptics.consume()
        if item.quantity > 1 {
            item.quantity -= 1
        } else {
            item.status = status
            item.consumedDate = Date()
            NotificationService.cancel(for: item.id)
            dismiss()
        }
    }

    private func deleteItem() {
        Haptics.warning()
        NotificationService.cancel(for: item.id)
        context.delete(item)
        dismiss()
    }
}
