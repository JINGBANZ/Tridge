import SwiftUI

/// Centered ghost item nudging the user toward their first scan.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("🥕")
                .font(.system(size: 64))
                .opacity(0.25)
                .grayscale(0.4)
            Text("Scan your first receipt")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.mutedInk)
            Image(systemName: "arrow.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.brandGreen.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ZStack {
        AppTheme.ChillBackground()
        EmptyStateView()
    }
}
