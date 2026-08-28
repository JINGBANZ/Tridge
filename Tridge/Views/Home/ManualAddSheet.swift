import SwiftUI

/// The values an Add as New carries over from a draft whose item turned out to
/// be closed, so nothing the user typed is lost.
struct ManualAddPrefill: Equatable {
    let name: String
    let artKey: String
    let quantity: Int64
    let storage: StorageLocation
    let expiryDay: InventoryDay
}

/// Hand-typed alternative to scanning: one edit page for every case. Quick-fill
/// chips (ranked from the Household's own purchase history) sit above the name
/// input; art resolves automatically from the name (remembered art first, then
/// `ArtInference`); quantity and expiry stay editable; a single Add button
/// confirms — grouping with a matching active item instead of duplicating it.
///
/// Every purchase creates its own physical root (ADR 0008); grouping is the
/// projection of exact-name roots, not a quantity rewritten in place.
struct ManualAddSheet: View {
    let session: HouseholdSession
    var prefill: ManualAddPrefill?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    @State private var name = ""
    @State private var artKey = ItemID.unknown.rawValue
    /// The name key the art was explicitly chosen for (picker or chip); auto
    /// inference backs off while the typed name still resolves to this key.
    @State private var artChosenForKey: String?
    @State private var quantity: Int64 = 1
    @State private var storage = StorageLocation.fridge
    @State private var expiryDay = InventoryDay.today().adding(days: 7) ?? InventoryDay.today()
    /// Which fields the user changed on purpose. A chip prefill, an inferred
    /// art, and a form default are deliberately absent, so none of them can
    /// overwrite metadata an existing same-name item already established
    /// (ADR 0011).
    @State private var explicitFields: Set<ExplicitMetadataField> = []
    @State private var showArtPicker = false
    @State private var isSaving = false
    /// History aggregates, built once at presentation: the history can't change
    /// while the sheet is up (adding dismisses it), and regrouping every row
    /// ever saved on each keystroke would hitch the keyboard once the household
    /// has a year of receipts.
    @State private var history = History()

    var body: some View {
        NavigationStack {
            Form {
                // Art still resolves behind the scenes in emoji-free mode (so
                // icons return when it's switched off) — only the display and
                // the picker entry point go.
                if !emojiFreeMode {
                    Section {
                        // Smaller than the detail sheet's hero: this page is
                        // form-first, so the fields keep the space.
                        HeroArtRow(emoji: Artwork.emoji(forKey: artKey),
                                   size: AppTheme.manualAddArtSize,
                                   needsArt: needsArt) {
                            showArtPicker = true
                        }
                    }
                }

                Section {
                    if !suggestions.isEmpty {
                        chipsRow
                    }
                    ItemFieldRows(namespace: "manualAdd",
                                  name: .editable($name),
                                  quantity: $quantity,
                                  storage: storageBinding,
                                  expiryDay: expiryBinding)
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
                        .disabled(trimmedName.isEmpty || isSaving)
                        .accessibilityIdentifier("manualAdd.saveButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            history = History(purchases: session.purchaseHistory, active: session.items,
                              today: InventoryDay.today())
            applyPrefill()
        }
        .onChange(of: name) { resolveArt() }
        .sheet(isPresented: $showArtPicker) {
            ArtPicker(selection: artPickerBinding)
        }
        .alert("Couldn't add that", isPresented: failureBinding) {
            Button("OK", role: .cancel) { session.clearFailure() }
        } message: {
            Text(session.lastFailure?.message ?? "")
        }
    }

    // MARK: Quick-fill chips

    /// One tappable chip per suggested past item, best match first. Tapping
    /// fills the form — it never commits anything, and never counts as an
    /// explicit metadata edit.
    private var chipsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        fill(with: suggestion)
                    } label: {
                        HStack(spacing: 5) {
                            if !emojiFreeMode {
                                Text(Artwork.emoji(forKey: suggestion.artKey))
                            }
                            Text(suggestion.displayName)
                                .lineLimit(1)
                                .foregroundStyle(AppTheme.ink)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.brandGreen.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("manualAdd.chip.\(suggestion.normalizedName)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    /// A distinct past item, aggregated from its purchase roots.
    struct Suggestion: Identifiable {
        let normalizedName: String
        let displayName: String
        let artKey: String
        /// Set when a non-expired active row exists — its date prefills the
        /// expiry field so an untouched Add preserves it.
        let activeExpiry: InventoryDay?
        let typicalShelfLifeDays: Int
        var id: String { normalizedName }
    }

    /// The once-built aggregates `suggestions` and `resolveArt` rank against.
    struct History {
        var byKey: [String: Suggestion] = [:]
        var entries: [SearchEntry] = []

        init() {}

        /// Built from every physical root the Household ever saved — including
        /// zero, deleted, and superseded ones — because purchase history is
        /// what the chips rank, not current stock.
        init(purchases: [PhysicalItemSnapshot], active: [InventoryItemSnapshot],
             today: InventoryDay) {
            // Expired batches are excluded: a chip that prefilled one would
            // date a brand-new purchase in the past, and it could never be the
            // batch an untouched Add preserves either — `PurchasePlanner` will
            // not group onto an expired same-name item (ADR 0014). Those names
            // fall through to today + their typical shelf life, which is what
            // the chip means for anything not currently in the fridge.
            let current = active.filter { !$0.isExpired(on: today) }
            let activeByKey = Dictionary(current.map { ($0.normalizedName, $0) },
                                         uniquingKeysWith: { first, _ in first })
            let groups = Dictionary(grouping: purchases.filter { !$0.normalizedName.isEmpty },
                                    by: \.normalizedName)
            for (key, roots) in groups {
                guard let latest = roots.max(by: { $0.purchaseDay < $1.purchaseDay }) else {
                    continue
                }
                byKey[key] = Suggestion(
                    normalizedName: key,
                    displayName: latest.name,
                    artKey: latest.artKey,
                    activeExpiry: activeByKey[key]?.expiryDay,
                    typicalShelfLifeDays: Self.typicalShelfLife(of: roots))
                entries.append(SearchEntry(normalizedName: key,
                                           lastUsed: latest.createdAt,
                                           useCount: roots.count))
            }
        }

        /// Median of the item's past purchase→expiry spans, in days.
        private static func typicalShelfLife(of roots: [PhysicalItemSnapshot]) -> Int {
            let spans = roots.map { max(1, $0.expiryDay.days(since: $0.purchaseDay)) }.sorted()
            return spans.isEmpty ? 7 : spans[spans.count / 2]
        }
    }

    /// The cached history ranked against the typed name — the only per-keystroke
    /// work. Empty input ranks by recency, so the chips double as "recently added".
    private var suggestions: [Suggestion] {
        NameSearch.rank(query: name, in: history.entries, limit: 6)
            .compactMap { history.byKey[$0.normalizedName] }
    }

    /// Chip tap: fill the form. In-fridge items prefill their current expiry
    /// (so an untouched Add preserves it); past items prefill today + their
    /// typical shelf life. Nothing here is an explicit edit.
    private func fill(with suggestion: Suggestion) {
        name = suggestion.displayName
        artKey = suggestion.artKey
        artChosenForKey = suggestion.normalizedName
        expiryDay = suggestion.activeExpiry
            ?? InventoryDay.today().adding(days: suggestion.typicalShelfLifeDays)
            ?? expiryDay
        explicitFields.remove(.art)
        explicitFields.remove(.expiryDay)
    }

    /// Carried over from a detail draft whose item turned out to be closed. The
    /// user chose these values on the previous sheet, so they are explicit.
    private func applyPrefill() {
        guard let prefill, name.isEmpty else { return }
        name = prefill.name
        artKey = prefill.artKey
        artChosenForKey = NameKey.normalize(prefill.name)
        quantity = prefill.quantity
        storage = prefill.storage
        expiryDay = prefill.expiryDay
        explicitFields = [.art, .storage, .expiryDay]
    }

    // MARK: Automatic art

    private var needsArt: Bool {
        artKey == ItemID.unknown.rawValue && !trimmedName.isEmpty
    }

    /// Tier 0 first — a name the household saved before keeps the art it was
    /// given (latest root wins) — then `ArtInference` for new names. Backs off
    /// while an explicit pick still covers the typed name.
    private func resolveArt() {
        let key = NameKey.normalize(name)
        if let chosen = artChosenForKey, chosen == key { return }
        artChosenForKey = nil
        explicitFields.remove(.art)
        // The cached aggregate already carries the latest root's art per key.
        if let remembered = history.byKey[key]?.artKey {
            artKey = remembered
        } else {
            artKey = ArtInference.itemID(for: name).rawValue
        }
    }

    private var artPickerBinding: Binding<String> {
        Binding(get: { artKey },
                set: {
                    artKey = $0
                    artChosenForKey = NameKey.normalize(name)
                    explicitFields.insert(.art)
                })
    }

    // MARK: Bindings

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var storageBinding: Binding<StorageLocation> {
        Binding(get: { storage },
                set: {
                    storage = $0
                    explicitFields.insert(.storage)
                })
    }

    private var expiryBinding: Binding<InventoryDay> {
        Binding(get: { expiryDay },
                set: {
                    expiryDay = $0
                    explicitFields.insert(.expiryDay)
                })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { session.lastFailure != nil },
                set: { if !$0 { session.clearFailure() } })
    }

    // MARK: Save

    /// Confirms one purchase. It always creates a fresh physical root; if an
    /// eligible same-name item is already in the fridge, the projector groups
    /// the two immediately and the reconciler makes that link permanent.
    private func add() {
        let today = InventoryDay.today()
        let draft = PurchaseDraft(itemID: UUID(), stockChangeID: UUID(), name: trimmedName,
                                  quantity: quantity, artKey: artKey, storage: storage,
                                  purchaseDay: today, expiryDay: expiryDay,
                                  // A hand-typed item's date is the user's,
                                  // whether they changed the prefill or
                                  // accepted it — no model produced it. Whether
                                  // it may overwrite an existing same-name
                                  // item's date is a separate question, and
                                  // `explicitMetadataFields` still answers it.
                                  expirySource: .userSet,
                                  explicitMetadataFields: explicitFields)
        isSaving = true
        Task {
            let saved = await session.addManualItem(draft)
            isSaving = false
            if saved {
                Haptics.success()
                dismiss()
            }
        }
    }
}
