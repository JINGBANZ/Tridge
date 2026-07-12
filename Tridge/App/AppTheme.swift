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

    /// Label color on filled (selected/active) chips and tags.
    static let chipSelectedLabel = Color.white

    /// Solid field/card surface: #FFFFFF light / #18231D dark.
    static let surfaceSolid = Color(light: 0xFFFFFF, dark: 0x18231D)

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
    /// Large art atop the item-detail sheet.
    static let heroArtSize: CGFloat = 96
    /// Art atop the manual-add sheet — smaller, so the form leads the page.
    static let manualAddArtSize: CGFloat = 64
    /// Review-sheet chips (quantity ×N, expiry date, Food Category, Storage).
    static let chipPadding = (h: CGFloat(8), v: CGFloat(3))
    static let chipSpacing: CGFloat = 4
    /// Soft chip fill: the chip's tint color at 12% (unselected filter options,
    /// review-row guess chips).
    static let chipSoftOpacity: Double = 0.12
    /// Review rows: name-to-receipt-text gap.
    static let reviewRowNameSpacing: CGFloat = 2
    /// Home's active-filter tags.
    static let filterChipPadding = (h: CGFloat(12), v: CGFloat(6))
    static let filterChipSpacing: CGFloat = 6
    /// The filter sheet's option chips — larger than Home's tags for easy tapping.
    static let filterSheetChipPadding = (h: CGFloat(14), v: CGFloat(8))
    /// Sheet chrome above the measured filter content: inline nav bar (44pt)
    /// plus bottom breathing room, so the sheet hugs the chip groups exactly.
    static let filterSheetChrome: CGFloat = 60
    /// Filter sheet layout; the padding also frames Home's active-filter bar.
    static let filterGroupSpacing: CGFloat = 22
    static let filterGroupTitleSpacing: CGFloat = 10
    static let filterBarPadding = (h: CGFloat(20), top: CGFloat(8))
    /// Home's active-filter tags: label-to-✕ gap.
    static let filterTagSpacing: CGFloat = 5
    /// The green dot on the header's filter glyph while a filter is active.
    static let filterDotSize: CGFloat = 6
    static let filterDotOffset = (x: CGFloat(4), y: CGFloat(-4))
    /// Header glyph size (filter and gear).
    static let headerGlyphSize: CGFloat = 20
    /// Pads the bare header glyphs' tappable area toward the 44pt minimum —
    /// the glyphs alone are ~15–20pt tall and easy to miss. Horizontal pad is
    /// capped at half the glyph spacing so neighboring targets don't overlap.
    static let headerButtonHitPad = (h: CGFloat(5), v: CGFloat(14))
    /// Home's "nothing matches" ghost under an active filter.
    static let ghostSpacing: CGFloat = 10
    static let ghostArtOpacity: Double = 0.5
    /// Drops the no-match ghost below the search bar rather than centering it.
    static let noMatchTopPad: CGFloat = 90
    /// The ✕ inside Home's active-filter tags sits slightly quieter than its label.
    static let filterTagDismissOpacity: Double = 0.75
    static let gridColumns = 4
    static let gridRowGap: CGFloat = 18
    static let gridColumnGap: CGFloat = 6
    static let screenMargin: CGFloat = 14
    static let scanButtonSize: CGFloat = 58
    /// Bottom padding that keeps scrollable/centered content clear of the
    /// floating scan button.
    static let scanButtonClearance: CGFloat = scanButtonSize + 40
    static let dropZoneHeight: CGFloat = 78
    static let dropZoneRadius: CGFloat = 20
    /// Home search field (Apple Music–style, item-grouping-search.html §6.2,
    /// owner-revised 2026-07-12): a rounded capsule parked below the header
    /// that scrolls up and tucks under it. A muted fill reads as a distinct
    /// field over the chilled background.
    static let searchFieldFill = Color(light: 0xDBE2DD, dark: 0x1E2A23)
    /// Padding inside the capsule, around the icon/text row.
    static let searchFieldPadding = (h: CGFloat(14), v: CGFloat(10))
    static let searchFieldIconGap: CGFloat = 8
    /// Vertical rhythm of the capsule row within the scroll content.
    static let searchBarPadding = (top: CGFloat(2), bottom: CGFloat(10))
    /// The circular ✕ cancel button that slides in to the right on focus.
    static let searchCancelSize: CGFloat = 34
    static let searchCancelGap: CGFloat = 8
    /// When focused, content rises so the capsule sits this far below the
    /// status bar (the header having faded away).
    static let searchFocusTopGap: CGFloat = 4
    /// Full height of the revealable search bar (capsule + its vertical
    /// padding). Overscrolling the grid by this much fully expands it; the
    /// reveal amount tracks the pull continuously up to here.
    static let searchRevealHeight: CGFloat = 52
    /// Emoji-free mode's home rows: name-first lines replacing the art grid.
    static let listRowPadding = (h: CGFloat(20), v: CGFloat(12))
    static let listRowQuantityGap: CGFloat = 8
    /// Settings rows: emoji icon chips on a soft green square (owner-picked
    /// "one card, danger apart" redesign, 2026-07-12).
    static let settingsIconChipSize: CGFloat = 30
    static let settingsIconChipRadius: CGFloat = 8
    static let settingsRowIconGap: CGFloat = 12

    // MARK: Type

    static let titleFont = Font.system(size: 28, weight: .heavy, design: .rounded)
    static let itemNameFont = Font.system(size: 13, weight: .semibold)
    /// Emoji-free mode's home rows — the name is the row, so it reads larger
    /// than the grid caption.
    static let listRowNameFont = Font.system(size: 15, weight: .semibold)
    static let pillFont = Font.system(size: 10, weight: .heavy)
    static let countFont = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let chipFont = Font.system(size: 10.5, weight: .bold)
    static let filterChipFont = Font.system(size: 13, weight: .semibold)
    /// The filter sheet's option chips.
    static let filterSheetChipFont = Font.system(size: 15, weight: .semibold)
    /// The filter sheet's uppercase group labels ("STORAGE", "FOOD CATEGORY").
    static let filterGroupLabelFont = Font.system(size: 12, weight: .bold)
    static let filterGroupLabelKerning: CGFloat = 0.8
    /// The ✕ inside Home's active-filter tags.
    static let filterTagXFont = Font.system(size: 9, weight: .bold)
    /// Home's "nothing matches" ghost: art + caption.
    static let ghostArtFont = Font.system(size: 34)
    static let ghostTextFont = Font.system(size: 13, weight: .semibold)
    static let searchFont = Font.system(size: 13, weight: .semibold)
    /// The ⓧ clear button inside the search field.
    static let searchClearFont = Font.system(size: 14)
    /// The ✕ inside the circular cancel button.
    static let searchCancelFont = Font.system(size: 13, weight: .semibold)
    /// The emoji inside settings icon chips.
    static let settingsIconFont = Font.system(size: 15)

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

    /// Home's standard settle spring: search-mode transitions (enter/exit,
    /// the inline clear button) and the drag ghost's appear/disappear.
    static let searchSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Pull-to-reveal expand/collapse of the search bar — slightly tighter so
    /// the bar snaps in step with the scroll settle.
    static let searchRevealSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
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
