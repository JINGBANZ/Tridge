import SwiftUI

/// One grid slot: frameless art on the background with pill, quantity badge,
/// and name — no tile, no card.
struct ItemSprite: View {
    let item: FridgeItem

    var body: some View {
        VStack(spacing: 3) {
            art
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
        .accessibilityLabel("\(item.name), \(accessibilityFreshness)")
    }

    private var art: some View {
        Text(Artwork.artwork(for: item))
            .font(.system(size: AppTheme.artPointSize))
            .shadow(color: AppTheme.artShadow.color.opacity(item.isExpired ? 0.6 : 1),
                    radius: AppTheme.artShadow.radius,
                    y: AppTheme.artShadow.y)
            .grayscale(item.isExpired ? AppTheme.expiredGrayscale : 0)
            .opacity(item.isExpired ? AppTheme.expiredOpacity : 1)
            .overlay(alignment: .topTrailing) {
                StatusPill(daysLeft: item.daysLeft)
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

    private var accessibilityFreshness: String {
        switch item.urgency {
        case .fresh, .soon: "expires in \(item.daysLeft) days"
        case .today: "expires today"
        case .expired: "expired \(-item.daysLeft) days ago"
        }
    }
}
