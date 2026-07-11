import SwiftUI
import SwiftData

/// Hand-typed alternative to scanning: name an item, pick art, set quantity
/// and expiry, and it lands in the fridge — no API key or LLM call involved.
struct ManualAddSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9

    @State private var name = ""
    @State private var artKey = ItemID.unknown.rawValue
    @State private var quantity = 1
    // A week out — a neutral starting point the user adjusts, unlike scanned
    // items whose expiry the LLM estimates.
    @State private var expiryDate = Calendar.current.date(byAdding: .day, value: 7,
                                                          to: Date()) ?? Date()
    @State private var showArtPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Button {
                            showArtPicker = true
                        } label: {
                            Text(Artwork.emoji(forKey: artKey))
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
                    TextField("Name (e.g. Milk)", text: $name)
                    LabeledContent("Quantity") {
                        TextField("1", value: quantityBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Expires", selection: $expiryDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Add an item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showArtPicker) {
            ArtPicker(selection: $artKey)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Typed quantities are kept in the stepper's old 1...99 bounds.
    private var quantityBinding: Binding<Int> {
        Binding(get: { quantity },
                set: { quantity = min(max($0, 1), 99) })
    }

    private func add() {
        let storageRaw = UserDefaults.standard.string(forKey: "defaultStorage") ?? ""
        let item = FridgeItem(
            name: trimmedName,
            artKey: artKey,
            quantity: quantity,
            storage: StorageLocation(rawValue: storageRaw) ?? .fridge,
            expiryDate: expiryDate,
            expirySource: .userSet)
        context.insert(item)
        Haptics.success()
        Task {
            // Permission is requested on first successful add, not at launch.
            await NotificationService.requestPermissionIfNeeded()
            NotificationService.schedule(for: item, hour: notificationHour)
        }
        dismiss()
    }
}

#if DEBUG
#Preview {
    ManualAddSheet()
        .modelContainer(PreviewData.container)
}
#endif
