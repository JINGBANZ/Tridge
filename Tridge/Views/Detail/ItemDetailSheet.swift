import SwiftUI
import SwiftData

/// Edit one item: art, name, quantity, storage, expiry, plus the
/// consume/delete actions. The field rows are the same `ItemFieldRows` form
/// manual add uses, so both sheets stay consistent.
struct ItemDetailSheet: View {
    @Bindable var item: FridgeItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9

    @State private var showArtPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HeroArtRow(emoji: Artwork.artwork(for: item)) {
                        showArtPicker = true
                    }
                }

                Section {
                    ItemFieldRows(namespace: "itemDetail",
                                  name: nameBinding,
                                  quantity: $item.quantity,
                                  storage: storageBinding,
                                  expiryDate: expiryBinding)
                    LabeledContent("Food Category", value: item.foodCategory.label)
                }

                Section {
                    Button("😋  Ate it") { consume(as: .eaten) }
                        .accessibilityIdentifier("itemDetail.ateButton")
                    Button("🗑️  Tossed it") { consume(as: .tossed) }
                        .accessibilityIdentifier("itemDetail.tossedButton")
                    Button("Delete", role: .destructive) { deleteItem() }
                        .accessibilityIdentifier("itemDetail.deleteButton")
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
    }

    // MARK: Bindings

    /// Renames go through `setName` so the merge/search key stays in sync.
    private var nameBinding: Binding<String> {
        Binding(get: { item.name }, set: { item.setName($0) })
    }

    private var storageBinding: Binding<StorageLocation> {
        Binding(get: { item.storage }, set: { item.storage = $0 })
    }

    /// Hand-edited dates become `.userSet` and reschedule both notifications.
    private var expiryBinding: Binding<Date> {
        Binding(get: { item.expiryDate },
                set: {
                    item.expiryDate = $0
                    item.expirySource = .userSet
                    NotificationService.schedule(for: item, hour: notificationHour)
                })
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
