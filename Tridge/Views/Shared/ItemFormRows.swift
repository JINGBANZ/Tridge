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

/// The editable core of an item: Name · Quantity · Storage · Expires, each a
/// label-left / value-right form row.
struct ItemFieldRows: View {
    /// Test-facing id prefix ("<screen>") so the shared rows expose distinct
    /// identifiers per host sheet — e.g. "manualAdd.nameField" vs
    /// "itemDetail.nameField".
    let namespace: String
    @Binding var name: String
    @Binding var quantity: Int
    @Binding var storage: StorageLocation
    @Binding var expiryDate: Date

    var body: some View {
        LabeledContent("Name") {
            TextField("e.g. Milk", text: $name)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("\(namespace).nameField")
        }
        QuantityRow(quantity: $quantity)
            .accessibilityIdentifier("\(namespace).quantityField")
        Picker("Storage", selection: $storage) {
            ForEach(StorageLocation.allCases, id: \.self) { location in
                Text(location.label).tag(location)
            }
        }
        .accessibilityIdentifier("\(namespace).storagePicker")
        DatePicker("Expires", selection: $expiryDate, displayedComponents: .date)
            .accessibilityIdentifier("\(namespace).expiryPicker")
    }
}

/// Type-in quantity (1–99) backed by its own text state so the field can be
/// emptied while retyping; each parsable number commits as typed, and losing
/// focus snaps the text back to the canonical clamped value.
private struct QuantityRow: View {
    @Binding var quantity: Int
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(quantity: Binding<Int>) {
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
            if let typed = Int(text) {
                quantity = min(max(typed, 1), 99)
            }
        }
        .onChange(of: isFocused) {
            if !isFocused { text = String(quantity) }
        }
        .onChange(of: quantity) {
            // External changes (e.g. "Ate it" decrementing) re-sync the field.
            if !isFocused { text = String(quantity) }
        }
    }
}
