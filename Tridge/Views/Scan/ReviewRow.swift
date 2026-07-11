import SwiftUI

/// One editable line of the review sheet: art, name (tap to edit), source
/// receipt text, the Food Category (derived from the art) and Storage chips,
/// a type-in quantity chip, and a tappable expiry-date chip.
struct ReviewRow: View {
    @Binding var item: ScanFlowModel.ReviewItem
    @State private var showDatePicker = false

    var body: some View {
        HStack(spacing: 9) {
            Text(item.emoji)
                .font(.system(size: 24))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $item.name)
                    .font(.system(size: 13, weight: .semibold))
                if let receiptText = item.receiptText {
                    Text(item.needsFix
                         ? "from \"\(receiptText)\" — tap to fix"
                         : "from \"\(receiptText)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(1)
                }
                HStack(spacing: AppTheme.chipSpacing) {
                    // Display-only: the category follows the item's art.
                    Text(item.foodCategory.label)
                        .font(AppTheme.chipFont)
                        .foregroundStyle(AppTheme.brandGreen)
                        .padding(.horizontal, AppTheme.chipPadding.h)
                        .padding(.vertical, AppTheme.chipPadding.v)
                        .background(AppTheme.brandGreen.opacity(0.12), in: Capsule())
                    storageChip
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                Text("×")
                TextField("1", value: quantityBinding, format: .number)
                    .keyboardType(.numberPad)
                    .fixedSize()
            }
            .font(AppTheme.chipFont.monospacedDigit())
            .foregroundStyle(AppTheme.mutedInk)
            .padding(.horizontal, AppTheme.chipPadding.h)
            .padding(.vertical, AppTheme.chipPadding.v)
            .background(AppTheme.mutedInk.opacity(0.12), in: Capsule())
            .accessibilityLabel("Quantity")

            Button {
                showDatePicker = true
            } label: {
                Text(item.needsFix && !item.userEditedDate
                     ? "Guess"
                     : item.expiryDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(AppTheme.chipFont)
                    .foregroundStyle(item.needsFix && !item.userEditedDate
                                     ? AppTheme.soon : AppTheme.brandGreen)
                    .padding(.horizontal, AppTheme.chipPadding.h)
                    .padding(.vertical, AppTheme.chipPadding.v)
                    .background(
                        (item.needsFix && !item.userEditedDate
                         ? AppTheme.soon : AppTheme.brandGreen).opacity(0.12),
                        in: Capsule())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showDatePicker) {
                DatePicker("Expires",
                           selection: Binding(
                               get: { item.expiryDate },
                               set: { item.expiryDate = $0; item.userEditedDate = true }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .frame(minWidth: 320)
                    .padding(8)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.vertical, 2)
    }

    /// Typed quantities are kept in the stepper's old 1...99 bounds.
    private var quantityBinding: Binding<Int> {
        Binding(get: { item.quantity },
                set: { item.quantity = min(max($0, 1), 99) })
    }

    /// The LLM's storage guess; the menu reassigns it before saving.
    private var storageChip: some View {
        Menu {
            Picker("Storage", selection: $item.storage) {
                ForEach(StorageLocation.allCases, id: \.self) { location in
                    Text(location.label).tag(location)
                }
            }
        } label: {
            Text(item.storage.label)
                .font(AppTheme.chipFont)
                .foregroundStyle(AppTheme.mutedInk)
                .padding(.horizontal, AppTheme.chipPadding.h)
                .padding(.vertical, AppTheme.chipPadding.v)
                .background(AppTheme.mutedInk.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Storage \(item.storage.label)")
    }
}
