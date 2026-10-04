import SwiftUI

/// One emoji-free home row: name, ×N, and the freshness pill — no art, no
/// card. `ItemSprite`'s counterpart when emoji-free mode is on.
struct ItemRow: View {
    let item: InventoryItemSnapshot
    let today: InventoryDay

    var body: some View {
        let daysLeft = item.daysLeft(from: today)

        HStack(spacing: AppTheme.listRowQuantityGap) {
            Text(item.name)
                .font(AppTheme.listRowNameFont)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if item.quantity > 1 {
                Text("×\(item.quantity)")
                    .font(AppTheme.countFont)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            Spacer(minLength: AppTheme.listRowQuantityGap)
            StatusPill(daysLeft: daysLeft)
        }
        .opacity(daysLeft < 0 ? AppTheme.expiredOpacity : 1)
        .padding(.horizontal, AppTheme.listRowPadding.h)
        .padding(.vertical, AppTheme.listRowPadding.v)
        // Full-width hit target: without this, taps between the name and the
        // pill would fall through to the background.
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(UrgencyRules.spokenFreshness(daysLeft: daysLeft))")
        .accessibilityIdentifier("home.item.\(item.normalizedName)")
    }
}
