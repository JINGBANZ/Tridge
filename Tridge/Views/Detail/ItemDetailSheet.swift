import SwiftUI

/// Edit one logical item: art, quantity, storage, expiry, plus the
/// consume/delete actions. The field rows are the same `ItemFieldRows` form
/// manual add uses, so both sheets stay consistent.
///
/// The name is presented read-only. A saved Item Name is immutable in the first
/// sharing release (ADR 0005): it is the identity every permanent merge claim
/// is made against, so correcting one means deleting the item and adding it
/// again. Manual Add and receipt Review keep it editable until the item saves.
struct ItemDetailSheet: View {
    /// The row as it was when the sheet opened — the baseline the draft is
    /// diffed against, so an untouched form writes nothing.
    let item: InventoryItemSnapshot
    let session: HouseholdSession
    let today: InventoryDay
    /// Offered when a stale draft turns out to address a closed batch.
    let onAddAsNew: (ManualAddPrefill) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    @State private var artKey: String
    @State private var quantity: Int64
    @State private var storage: StorageLocation
    @State private var expiryDay: InventoryDay
    @State private var showArtPicker = false
    @State private var showDeleteConfirmation = false
    @State private var isSaving = false

    init(item: InventoryItemSnapshot, session: HouseholdSession, today: InventoryDay,
         onAddAsNew: @escaping (ManualAddPrefill) -> Void) {
        self.item = item
        self.session = session
        self.today = today
        self.onAddAsNew = onAddAsNew
        _artKey = State(initialValue: item.artKey)
        _quantity = State(initialValue: item.quantity)
        _storage = State(initialValue: item.storage)
        _expiryDay = State(initialValue: item.expiryDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Emoji-free mode drops the hero art (and with it the picker
                // entry point); the stored artKey stays untouched.
                if !emojiFreeMode {
                    Section {
                        HeroArtRow(emoji: Artwork.emoji(forKey: artKey)) {
                            showArtPicker = true
                        }
                    }
                }

                Section {
                    ItemFieldRows(namespace: "itemDetail",
                                  name: .readOnly(item.name),
                                  quantity: $quantity,
                                  storage: $storage,
                                  expiryDay: $expiryDay)
                    LabeledContent("Food Category", value: foodCategory.label)
                } footer: {
                    Text("Item names can't be changed once saved. To rename, delete this item and add it again.")
                }

                Section {
                    Button("😋  Ate it") { consume(.eaten) }
                        .accessibilityIdentifier("itemDetail.ateButton")
                    Button("🗑️  Tossed it") { consume(.tossed) }
                        .accessibilityIdentifier("itemDetail.tossedButton")
                    Button("Delete", role: .destructive) { showDeleteConfirmation = true }
                        .accessibilityIdentifier("itemDetail.deleteButton")
                }
                .disabled(isSaving)
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("itemDetail.doneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showArtPicker) {
            ArtPicker(selection: $artKey)
        }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its history stays in this fridge's export, but it won't come back.")
        }
        // A draft whose item is gone is the one failure with somewhere to go:
        // the values the user typed become a new item rather than being lost.
        .alert("That item is gone", isPresented: staleBinding) {
            Button("Add as New") { addAsNew() }
            Button("Cancel", role: .cancel) { session.clearFailure(); dismiss() }
        } message: {
            Text("Someone removed it, or it was cleared. Your changes weren't saved.")
        }
        .alert("Couldn't save", isPresented: otherFailureBinding) {
            Button("OK", role: .cancel) { session.clearFailure() }
        } message: {
            Text(session.lastFailure?.message ?? "")
        }
    }

    /// Follows the art, exactly as it does everywhere else: changing the art is
    /// how the user recategorizes an item.
    private var foodCategory: FoodCategory {
        (ItemID(rawValue: artKey) ?? .unknown).foodCategory
    }

    /// The row as the session projects it now, which a consume or a remote
    /// import may have moved since the sheet opened.
    private var current: InventoryItemSnapshot? {
        session.items.first { $0.id == item.id || $0.memberIDs.contains(item.id) }
    }

    // MARK: Actions

    /// Commits only the fields the user actually moved. Quantity commits the
    /// difference from what this sheet could see, so a member's operation that
    /// arrived meanwhile still composes rather than being overwritten.
    private func save() {
        let targetQuantity = quantity == item.quantity ? nil : quantity
        let art = artKey == item.artKey ? nil : artKey
        let location = storage == item.storage ? nil : storage
        let expiry = expiryDay == item.expiryDay ? nil : expiryDay
        guard targetQuantity != nil || art != nil || location != nil || expiry != nil else {
            dismiss()
            return
        }

        isSaving = true
        Task {
            let saved = await session.updateItem(item.id, targetQuantity: targetQuantity,
                                                 artKey: art, storage: location,
                                                 expiryDay: expiry)
            isSaving = false
            if saved { dismiss() }
        }
    }

    private func consume(_ reason: StockReason) {
        Haptics.consume()
        isSaving = true
        Task {
            let saved = reason == .eaten
                ? await session.eatOne(item.id)
                : await session.tossOne(item.id)
            isSaving = false
            guard saved else { return }
            // The last unit leaving takes the row off Home, so there is nothing
            // left for this sheet to edit.
            if let refreshed = current {
                quantity = refreshed.quantity
            } else {
                dismiss()
            }
        }
    }

    private func deleteItem() {
        Haptics.warning()
        isSaving = true
        Task {
            let deleted = await session.deleteItem(item.id)
            isSaving = false
            if deleted { dismiss() }
        }
    }

    private func addAsNew() {
        session.clearFailure()
        let prefill = ManualAddPrefill(name: item.name, artKey: artKey, quantity: quantity,
                                       storage: storage, expiryDay: expiryDay)
        dismiss()
        onAddAsNew(prefill)
    }

    // MARK: Failure routing

    private var staleBinding: Binding<Bool> {
        Binding(get: { session.lastFailure?.reason == .itemUnavailable },
                set: { if !$0 { session.clearFailure() } })
    }

    private var otherFailureBinding: Binding<Bool> {
        Binding(get: {
            guard let failure = session.lastFailure else { return false }
            return failure.reason != .itemUnavailable
        }, set: { if !$0 { session.clearFailure() } })
    }
}
