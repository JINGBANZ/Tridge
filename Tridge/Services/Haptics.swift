import UIKit

/// The three haptic moments from the design tokens.
enum Haptics {
    /// Items added to the fridge.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Eat/toss consume action.
    static func consume() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Item deleted.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
