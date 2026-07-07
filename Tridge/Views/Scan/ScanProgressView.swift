import SwiftUI

/// Full-screen wait state while the LLM reads the receipt.
struct ScanProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wobble = false

    var body: some View {
        ZStack {
            AppTheme.ChillBackground()
            VStack(spacing: 18) {
                Text("🧾")
                    .font(.system(size: 64))
                    .rotationEffect(.degrees(wobble ? 6 : -6))
                    .scaleEffect(wobble ? 1.06 : 0.96)
                    .shadow(color: AppTheme.artShadow.color,
                            radius: AppTheme.artShadow.radius,
                            y: AppTheme.artShadow.y)
                Text("Reading your receipt…")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                ProgressView()
                    .tint(AppTheme.brandGreen)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                wobble = true
            }
        }
    }
}

#Preview {
    ScanProgressView()
}
