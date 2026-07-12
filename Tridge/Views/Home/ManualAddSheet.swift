import SwiftUI
import SwiftData

/// Hand-typed alternative to scanning: one edit page for every case. Quick-fill
/// chips (ranked from the household's own history) sit above the name input;
/// art resolves automatically from the name (remembered art first, then
/// `ArtInference`); quantity and expiry stay editable; a single Add button
/// confirms — merging into a matching active item instead of duplicating it.
struct ManualAddSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationHour") private var notificationHour = 9
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    /// Every row ever saved (any status) — the suggestion and remembered-art
    /// source. Consumed rows are never deleted, so history is complete.
    @Query private var allItems: [FridgeItem]

    @State private var name = ""
    @State private var artKey = ItemID.unknown.rawValue
    /// The name key the art was explicitly chosen for (picker or chip); auto
    /// inference backs off while the typed name still resolves to this key.
    @State private var artChosenForKey: String?
    @State private var quantity = 1
    @State private var storage = StorageLocation.fridge
    // A week out — a neutral starting point the user adjusts, unlike scanned
    // items whose expiry the LLM estimates.
    @State private var expiryDate = Calendar.current.date(byAdding: .day, value: 7,
                                                          to: Date()) ?? Date()
    /// Distinguishes a deliberate date edit from a chip prefill: on a merge,
    /// only an edited date overwrites the existing item's expiry.
    @State private var expiryEdited = false
    @State private var showArtPicker = false

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
                                  name: $name,
                                  quantity: $quantity,
                                  storage: $storage,
                                  expiryDate: expiryBinding)
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
                        .accessibilityIdentifier("manualAdd.saveButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: name) { resolveArt() }
        .sheet(isPresented: $showArtPicker) {
            ArtPicker(selection: artPickerBinding)
        }
    }

    // MARK: Quick-fill chips

    /// One tappable chip per suggested past item, best match first. Tapping
    /// fills the form — it never commits anything.
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
                }
            }
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    /// A distinct past item, aggregated from its history rows.
    private struct Suggestion: Identifiable {
        let normalizedName: String
        let displayName: String
        let artKey: String
        /// Set when a non-expired active row exists — its date prefills the
        /// expiry field so an untouched Add preserves it on merge.
        let activeExpiry: Date?
        let typicalShelfLifeDays: Int
        var id: String { normalizedName }
    }

    /// History grouped by name key, ranked against the typed name. Empty
    /// input ranks by recency, so the chips double as "recently added".
    private var suggestions: [Suggestion] {
        var byKey: [String: Suggestion] = [:]
        var entries: [SearchEntry] = []
        let groups = Dictionary(grouping: allItems.filter { !$0.normalizedName.isEmpty },
                                by: \.normalizedName)
        for (key, rows) in groups {
            guard let latest = rows.max(by: { $0.purchaseDate < $1.purchaseDate }) else { continue }
            // Expired rows never absorb a new purchase, so their chip fills a
            // fresh batch instead of advertising ×N.
            let activeRow = rows
                .filter { $0.status == .active && !$0.isExpired }
                .max(by: { $0.purchaseDate < $1.purchaseDate })
            byKey[key] = Suggestion(
                normalizedName: key,
                displayName: latest.name,
                artKey: latest.artKey,
                activeExpiry: activeRow?.expiryDate,
                typicalShelfLifeDays: Self.typicalShelfLife(of: rows))
            entries.append(SearchEntry(normalizedName: key,
                                       lastUsed: latest.purchaseDate,
                                       useCount: rows.count))
        }
        return NameSearch.rank(query: name, in: entries, limit: 6)
            .compactMap { byKey[$0.normalizedName] }
    }

    /// Median of the item's past purchase→expiry spans, in days.
    private static func typicalShelfLife(of rows: [FridgeItem]) -> Int {
        let spans = rows.compactMap {
            Calendar.current.dateComponents([.day], from: $0.purchaseDate,
                                            to: $0.expiryDate).day
        }.map { max(1, $0) }.sorted()
        return spans.isEmpty ? 7 : spans[spans.count / 2]
    }

    /// Chip tap: fill the form. In-fridge items prefill their current expiry
    /// (so an untouched Add preserves it); past items prefill today + their
    /// typical shelf life.
    private func fill(with suggestion: Suggestion) {
        name = suggestion.displayName
        artKey = suggestion.artKey
        artChosenForKey = suggestion.normalizedName
        expiryDate = suggestion.activeExpiry
            ?? Calendar.current.date(byAdding: .day,
                                     value: suggestion.typicalShelfLifeDays,
                                     to: Date())
            ?? expiryDate
        expiryEdited = false
    }

    // MARK: Automatic art

    private var needsArt: Bool {
        artKey == ItemID.unknown.rawValue && !trimmedName.isEmpty
    }

    /// Tier 0 first — a name the household saved before keeps the art it was
    /// given (latest row wins) — then `ArtInference` for new names. Backs off
    /// while an explicit pick still covers the typed name.
    private func resolveArt() {
        let key = NameKey.normalize(name)
        if let chosen = artChosenForKey, chosen == key { return }
        artChosenForKey = nil
        if let remembered = allItems
            .filter({ $0.normalizedName == key && !key.isEmpty })
            .max(by: { $0.purchaseDate < $1.purchaseDate })?.artKey {
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
                })
    }

    // MARK: Bindings

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var expiryBinding: Binding<Date> {
        Binding(get: { expiryDate },
                set: {
                    expiryDate = $0
                    expiryEdited = true
                })
    }

    // MARK: Save

    /// Groups into a matching active item (quantity adds; the existing expiry
    /// stays unless the user deliberately edited the date) or inserts a new
    /// row. Only an explicit edit can overwrite a date — never a prefill.
    private func add() {
        let active = allItems.filter { $0.status == .active }
        var scheduleTarget: FridgeItem?

        if case .merge(let id, let resultingQuantity) = MergePlanner.decide(
               name: trimmedName, quantity: quantity,
               existing: active.map(\.mergeCandidate)),
           let target = active.first(where: { $0.id == id }) {
            target.quantity = resultingQuantity
            if expiryEdited {
                target.expiryDate = expiryDate
                target.expirySource = .userSet
                scheduleTarget = target
            }
        } else {
            let item = FridgeItem(
                name: trimmedName,
                artKey: artKey,
                quantity: quantity,
                storage: storage,
                expiryDate: expiryDate,
                expirySource: .userSet)
            context.insert(item)
            scheduleTarget = item
        }
        Haptics.success()
        if let scheduleTarget {
            Task {
                // Permission is requested on first successful add, not at launch.
                await NotificationService.requestPermissionIfNeeded()
                NotificationService.schedule(for: scheduleTarget, hour: notificationHour)
            }
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
