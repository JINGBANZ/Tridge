import SwiftUI

/// Grid of the curated item vocabulary; tapping picks new art for the item.
struct ArtPicker: View {
    /// The item's artKey (an ItemID rawValue).
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                    ForEach(ItemID.allCases, id: \.rawValue) { id in
                        Button {
                            selection = id.rawValue
                            dismiss()
                        } label: {
                            Text(id.emoji)
                                .font(.system(size: 34))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    id.rawValue == selection ? AppTheme.brandGreen.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel(id.rawValue.replacingOccurrences(of: "_", with: " "))
                    }
                }
                .padding()
            }
            .navigationTitle("Pick art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
