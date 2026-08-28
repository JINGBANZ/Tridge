import SwiftUI

/// The pieces every item-editing sheet shares — the tappable hero art and the
/// core field rows — so manual add and item detail render the same form
/// (design/item-grouping-search.html §6.1: label-left / value-right rows).

/// Centered tappable art atop the sheet; opens the art picker.
struct HeroArtRow: View {
    let emoji: String
    var size: CGFloat = AppTheme.heroArtSize
    /// Draws the dashed "this needs you" ring when art resolution came up empty.
    var needsArt = false
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Text(emoji)
                    .font(.system(size: size))
                    .shadow(color: AppTheme.artShadow.color,
                            radius: AppTheme.artShadow.radius,
                            y: AppTheme.artShadow.y)
                    .padding(8)
                    .overlay {
                        if needsArt {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(AppTheme.soon,
                                              style: StrokeStyle(lineWidth: 1.5,
                                                                 dash: [5, 4]))
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change art")
            Spacer()
        }
        .listRowBackground(Color.clear)
    }
}

/// Whether the sheet may still change the item's name.
///
/// A name is editable in a manual or receipt-review draft and immutable once
/// saved (ADR 0005) — that is what keeps every exact-name merge permanent, so
/// Item Detail presents the saved name as text rather than a field.
enum ItemNameField {
    case editable(Binding<String>)
    case readOnly(String)
}

/// The editable core of an item: Name · Quantity · Storage · Expires, each a
/// label-left / value-right form row.
struct ItemFieldRows: View {
    /// Test-facing id prefix ("<screen>") so the shared rows expose distinct
    /// identifiers per host sheet — e.g. "manualAdd.nameField" vs
    /// "itemDetail.nameField".
    let namespace: String
    let name: ItemNameField
    @Binding var quantity: Int64
    @Binding var storage: StorageLocation
    @Binding var expiryDay: InventoryDay

    var body: some View {
        nameRow
        QuantityRow(quantity: $quantity)
            .accessibilityIdentifier("\(namespace).quantityField")
        Picker("Storage", selection: $storage) {
            ForEach(StorageLocation.allCases, id: \.self) { location in
                Text(location.label).tag(location)
            }
        }
        .accessibilityIdentifier("\(namespace).storagePicker")
        DatePicker("Expires", selection: expiryDateBinding, displayedComponents: .date)
            .accessibilityIdentifier("\(namespace).expiryPicker")
    }

    @ViewBuilder
    private var nameRow: some View {
        switch name {
        case .editable(let binding):
            LabeledContent("Name") {
                TextField("e.g. Milk", text: binding)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("\(namespace).nameField")
            }
        case .readOnly(let value):
            LabeledContent("Name", value: value)
                .accessibilityIdentifier("\(namespace).nameField")
        }
    }

    /// The civil day rendered for a viewer in the device's time zone. The
    /// stored value stays an ordinal (ADR 0003), so two members in different
    /// zones still agree on the expiry date.
    private var expiryDateBinding: Binding<Date> {
        Binding(get: { expiryDay.startOfDay(in: .current) ?? Date() },
                set: { date in
                    if let day = InventoryDay(date: date, calendar: .current) {
                        expiryDay = day
                    }
                })
    }
}

/// Type-in quantity backed by its own text state so the field can be emptied
/// while retyping; each parsable positive number commits as typed, and losing
/// focus snaps the text back to the canonical value.
///
/// There is no product cap: a quantity is any positive whole number the store
/// can represent (ADR 0004), and an unparsable or nonpositive entry is simply
/// not committed rather than silently clamped to something the user never chose.
private struct QuantityRow: View {
    @Binding var quantity: Int64
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(quantity: Binding<Int64>) {
        _quantity = quantity
        _text = State(initialValue: String(quantity.wrappedValue))
    }

    var body: some View {
        LabeledContent("Quantity") {
            TextField("1", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
        }
        .onChange(of: text) {
            do {
                quantity = try InventoryQuantity.parse(text)
            } catch InventoryCommandError.quantityOutOfRange {
                // Past what the store can hold. The digits are refused rather
                // than left on screen: the binding would keep the last
                // representable value, and Done would save a number the user
                // never saw.
                text = String(quantity)
            } catch {
                // Empty, or not a number yet — the field is mid-edit and the
                // last committed value still stands.
            }
        }
        .onChange(of: isFocused) {
            if !isFocused { text = String(quantity) }
        }
        .onChange(of: quantity) {
            // External changes (e.g. a remote import) re-sync the field.
            if !isFocused { text = String(quantity) }
        }
    }
}
