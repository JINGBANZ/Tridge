import SwiftUI
import UIKit

/// The design tokens from design/fridge-design.html — every visual constant in
/// the app comes from here; no magic colors or sizes in views.
enum AppTheme {
    // MARK: Colors

    static let brandGreen = Color(hex: 0x2F7D4E)
    static let fresh = Color(hex: 0x3E9463)
    static let soon = Color(hex: 0xD98A26)
    static let expired = Color(hex: 0xD9534A)

    /// Primary text: #22281F light / #E8ECE6 dark.
    static let ink = Color(light: 0x22281F, dark: 0xE8ECE6)
    static let mutedInk = Color(light: 0x6C766D, dark: 0x99A294)

    /// bg.chill gradient: #EAF4EE → #E2EDF3 light, #101B16 → #0F1620 dark.
    static let bgTop = Color(light: 0xEAF4EE, dark: 0x101B16)
    static let bgBottom = Color(light: 0xE2EDF3, dark: 0x0F1620)

    /// Scan button gradient.
    static let scanTop = Color(hex: 0x37985F)
    static let scanBottom = Color(hex: 0x25714A)

    static func color(for urgency: Urgency) -> Color {
        switch urgency {
        case .fresh: fresh
        case .soon: soon
        case .today, .expired: expired
        }
    }

    /// The chilled-air background: soft cool gradient with a faint top glow,
    /// like light inside a fridge.
    struct ChillBackground: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) {
                    RadialGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.06 : 0.85), .clear],
                        center: UnitPoint(x: 0.5, y: -0.1),
                        startRadius: 0, endRadius: 420)
                }
                .ignoresSafeArea()
        }
    }

    // MARK: Metrics

    static let spriteCellSize = CGSize(width: 64, height: 60)
    static let artPointSize: CGFloat = 44
    /// Large art atop the item-detail and manual-add sheets.
    static let heroArtSize: CGFloat = 96
    /// Review-sheet chips (quantity ×N, expiry date).
    static let chipPadding = (h: CGFloat(8), v: CGFloat(3))
    static let gridColumns = 4
    static let gridRowGap: CGFloat = 18
    static let gridColumnGap: CGFloat = 6
    static let screenMargin: CGFloat = 14
    static let scanButtonSize: CGFloat = 58
    static let dropZoneHeight: CGFloat = 78
    static let dropZoneRadius: CGFloat = 20

    // MARK: Type

    static let titleFont = Font.system(size: 28, weight: .heavy, design: .rounded)
    static let itemNameFont = Font.system(size: 11, weight: .semibold)
    static let pillFont = Font.system(size: 10, weight: .heavy)
    static let countFont = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let chipFont = Font.system(size: 10.5, weight: .bold)

    // MARK: Effects

    /// Item art drop shadow: 28% ink, y=5, blur=7.
    static let artShadow = (color: Color.black.opacity(0.28), radius: CGFloat(3.5), y: CGFloat(5))

    /// Expired art treatment: 70% grayscale + 80% opacity.
    static let expiredGrayscale: Double = 0.7
    static let expiredOpacity: Double = 0.8

    /// Staggered pop-in on load: 0.03s per item, scale 0.7 → 1.
    static let popInDelayPerItem: Double = 0.03
    static let popInStartScale: CGFloat = 0.7
    /// Only animate the initial screenful; later lazy cells must stay cheap to scroll.
    static let popInItemLimit = 16
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// A dynamic color with distinct light/dark hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }
}
