import SwiftUI

/// Freshness capsule riding the art's top-right shoulder: "12d" / "Today" / "✕ 1d".
struct StatusPill: View {
    let daysLeft: Int

    var body: some View {
        Text(UrgencyRules.pillLabel(daysLeft: daysLeft))
            .font(AppTheme.pillFont)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.color(for: UrgencyRules.urgency(daysLeft: daysLeft)), in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 2.5, y: 2)
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusPill(daysLeft: 12)
        StatusPill(daysLeft: 2)
        StatusPill(daysLeft: 0)
        StatusPill(daysLeft: -1)
    }
    .padding()
}
