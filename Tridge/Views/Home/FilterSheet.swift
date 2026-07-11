import SwiftUI

/// The filter button's half sheet: at most one Storage and one Food Category
/// selection, applied to the grid live behind the sheet. `nil` = "All" on that
/// axis. Dismissing keeps the filters; Home's active-filter tags remove them.
struct FilterSheet: View {
    @Binding var storage: StorageLocation?
    @Binding var category: FoodCategory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.filterGroupSpacing) {
                    group("Storage") {
                        chip("All", isSelected: storage == nil) { storage = nil }
                        ForEach(StorageLocation.allCases, id: \.self) { option in
                            chip(option.label, isSelected: storage == option) { storage = option }
                        }
                    }
                    group("Food Category") {
                        chip("All", isSelected: category == nil) { category = nil }
                        ForEach(FoodCategory.allCases, id: \.self) { option in
                            chip(option.label, isSelected: category == option) { category = option }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.filterBarPadding.h)
                .padding(.top, AppTheme.filterBarPadding.top)
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") {
                        storage = nil
                        category = nil
                    }
                    .disabled(storage == nil && category == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func group(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.filterGroupTitleSpacing) {
            Text(title.uppercased())
                .font(AppTheme.filterGroupLabelFont)
                .kerning(AppTheme.filterGroupLabelKerning)
                .foregroundStyle(AppTheme.mutedInk)
            FlowLayout(spacing: AppTheme.filterChipSpacing) {
                chips()
            }
        }
    }

    private func chip(_ label: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            Text(label)
                .font(AppTheme.filterChipFont)
                .foregroundStyle(isSelected ? AppTheme.chipSelectedLabel : AppTheme.ink)
                .padding(.horizontal, AppTheme.filterChipPadding.h)
                .padding(.vertical, AppTheme.filterChipPadding.v)
                .background(isSelected ? AppTheme.brandGreen : AppTheme.mutedInk.opacity(0.12),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Left-aligned wrapping row of variable-width chips; rows break at the
/// proposed width like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview {
    struct Host: View {
        @State var storage: StorageLocation? = .freezer
        @State var category: FoodCategory?
        var body: some View {
            FilterSheet(storage: $storage, category: $category)
        }
    }
    return Host()
}
#endif
