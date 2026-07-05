import SwiftUI

/// One editable line of the review sheet: art, name (tap to edit), source
/// receipt text, and a tappable expiry-date chip.
struct ReviewRow: View {
    @Binding var item: ScanFlowModel.ReviewItem
    @State private var showDatePicker = false

    var body: some View {
        HStack(spacing: 9) {
            Text(item.emoji)
                .font(.system(size: 24))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    TextField("Name", text: $item.name)
                        .font(.system(size: 13, weight: .semibold))
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                }
                if let receiptText = item.receiptText {
                    Text(item.lowConfidence
                         ? "from \"\(receiptText)\" — tap to fix"
                         : "from \"\(receiptText)\"")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                showDatePicker = true
            } label: {
                Text(item.lowConfidence && !item.userEditedDate
                     ? "Guess"
                     : item.expiryDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(item.lowConfidence && !item.userEditedDate
                                     ? AppTheme.soon : AppTheme.brandGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (item.lowConfidence && !item.userEditedDate
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
