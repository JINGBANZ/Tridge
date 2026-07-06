import SwiftUI

/// One editable line of the review sheet: art, name (tap to edit), source
/// receipt text, and tappable quantity + expiry-date chips.
struct ReviewRow: View {
    @Binding var item: ScanFlowModel.ReviewItem
    @State private var showDatePicker = false
    @State private var showQuantityStepper = false

    var body: some View {
        HStack(spacing: 9) {
            Text(item.emoji)
                .font(.system(size: 24))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 2)

            VStack(alignment: .leading, spacing: 1) {
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
            }

            Spacer(minLength: 4)

            Button {
                showQuantityStepper = true
            } label: {
                Text("×\(item.quantity)")
                    .font(AppTheme.chipFont.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedInk)
                    .padding(.horizontal, AppTheme.chipPadding.h)
                    .padding(.vertical, AppTheme.chipPadding.v)
                    .background(AppTheme.mutedInk.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Quantity \(item.quantity)")
            .popover(isPresented: $showQuantityStepper) {
                Stepper("×\(item.quantity)", value: $item.quantity, in: 1...99)
                    .font(AppTheme.stepperPopoverFont.monospacedDigit())
                    .padding(.horizontal, AppTheme.stepperPopoverPadding.h)
                    .padding(.vertical, AppTheme.stepperPopoverPadding.v)
                    .presentationCompactAdaptation(.popover)
            }

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
}
