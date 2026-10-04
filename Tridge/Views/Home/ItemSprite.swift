import SwiftUI

/// One grid slot: frameless art on the background with pill, quantity badge,
/// and name — no tile, no card.
///
/// It renders one *logical* item: the projection of every physical purchase root
/// permanent merge claims have joined, so a ×3 milk may be three separate
/// receipts.
struct ItemSprite: View {
    let item: InventoryItemSnapshot
    let today: InventoryDay

    var body: some View {
        let daysLeft = item.daysLeft(from: today)

        VStack(spacing: 3) {
            art(daysLeft: daysLeft)
                .frame(width: AppTheme.spriteCellSize.width,
                       height: AppTheme.spriteCellSize.height)
            Text(item.name)
                .font(AppTheme.itemNameFont)
                .foregroundStyle(AppTheme.mutedInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 70)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(UrgencyRules.spokenFreshness(daysLeft: daysLeft))")
        .accessibilityIdentifier("home.item.\(item.normalizedName)")
    }

    private func art(daysLeft: Int) -> some View {
        let isExpired = daysLeft < 0

        return Text(Artwork.emoji(forKey: item.artKey))
            .font(.system(size: AppTheme.artPointSize))
            .shadow(color: AppTheme.artShadow.color.opacity(isExpired ? 0.6 : 1),
                    radius: AppTheme.artShadow.radius,
                    y: AppTheme.artShadow.y)
            .grayscale(isExpired ? AppTheme.expiredGrayscale : 0)
            .opacity(isExpired ? AppTheme.expiredOpacity : 1)
            .overlay(alignment: .topTrailing) {
                StatusPill(daysLeft: daysLeft)
                    .offset(x: 10, y: -7)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .font(.system(size: 9.5, weight: .heavy).monospacedDigit())
                        .foregroundStyle(AppTheme.mutedInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .offset(x: 4, y: 3)
                }
            }
    }
}
