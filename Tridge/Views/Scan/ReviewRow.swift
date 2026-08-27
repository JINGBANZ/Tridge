import SwiftUI

/// One editable line of the review sheet: art, name (tap to edit), source
/// receipt text, the Food Category (derived from the art) and Storage chips,
/// a type-in quantity chip, and a tappable expiry-date chip.
struct ReviewRow: View {
    @Binding var item: ScanFlowModel.ReviewItem
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false
    @State private var showDatePicker = false

    var body: some View {
        HStack(spacing: 9) {
            if !emojiFreeMode {
                Text(item.emoji)
                    .font(.system(size: 24))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 2)
            }

            VStack(alignment: .leading, spacing: AppTheme.reviewRowNameSpacing) {
                TextField("Name", text: $item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("review.row.name")
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
                        .background(AppTheme.brandGreen.opacity(AppTheme.chipSoftOpacity), in: Capsule())
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
            .background(AppTheme.mutedInk.opacity(AppTheme.chipSoftOpacity), in: Capsule())
            .accessibilityLabel("Quantity")

            Button {
                showDatePicker = true
            } label: {
                Text(item.needsFix && !item.userEditedDate ? "Guess" : expiryLabel)
                    .font(AppTheme.chipFont)
                    .foregroundStyle(item.needsFix && !item.userEditedDate
                                     ? AppTheme.soon : AppTheme.brandGreen)
                    .padding(.horizontal, AppTheme.chipPadding.h)
                    .padding(.vertical, AppTheme.chipPadding.v)
                    .background(
                        (item.needsFix && !item.userEditedDate
                         ? AppTheme.soon : AppTheme.brandGreen).opacity(AppTheme.chipSoftOpacity),
                        in: Capsule())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showDatePicker) {
                DatePicker("Expires", selection: expiryBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .frame(minWidth: 320)
                    .padding(8)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.vertical, 2)
    }

    /// A quantity is any positive whole number the store can represent
    /// (ADR 0004); a nonpositive or unparsable entry is simply not committed
    /// rather than clamped to something the user never chose.
    private var quantityBinding: Binding<Int64> {
        Binding(get: { item.quantity },
                set: { if $0 > 0 { item.quantity = $0 } })
    }

    private var expiryLabel: String {
        let date = item.expiryDay.startOfDay(in: .current) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// A date the user picks here is an explicit edit: it saves as `.userSet`
    /// and is never overwritten by a later model guess (ADR 0011).
    private var expiryBinding: Binding<Date> {
        Binding(get: { item.expiryDay.startOfDay(in: .current) ?? Date() },
                set: { date in
                    guard let day = InventoryDay(date: date, calendar: .current) else { return }
                    item.expiryDay = day
                    item.explicitFields.insert(.expiryDay)
                })
    }

    /// The LLM's storage guess; the menu reassigns it before saving, and a
    /// reassignment counts as a deliberate edit.
    private var storageChip: some View {
        Menu {
            Picker("Storage", selection: storageBinding) {
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
                .background(AppTheme.mutedInk.opacity(AppTheme.chipSoftOpacity), in: Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Storage \(item.storage.label)")
    }

    private var storageBinding: Binding<StorageLocation> {
        Binding(get: { item.storage },
                set: {
                    item.storage = $0
                    item.explicitFields.insert(.storage)
                })
    }
}
