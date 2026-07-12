import SwiftUI
import UIKit

/// The live 0…1 openness of the search bar, driven by the scroll offset. Kept in
/// its own observable so only the bar overlay and occluder re-render as it
/// changes each scroll frame — `HomeView`'s body (which hosts the grid) does not
/// read it, so the grid is never re-hosted mid-scroll.
@Observable final class RevealModel {
    var progress: CGFloat = 0
}

/// A `UIScrollView` that hosts SwiftUI `content` and reports its live distance
/// past the top (`onScroll`) — the piece SwiftUI's own `ScrollView` can't do
/// without a layout cycle, because here the scroll lives in UIKit. The hosted
/// content leads with a transparent reveal spacer (height `revealHeight`) that
/// scrolls naturally with the grid; the visible capsule is a SwiftUI overlay
/// whose height tracks the spacer, so the search bar expands and collapses
/// continuously under the finger while the grid rises to meet it (no gap).
///
/// `topInset` reserves the header band (constant — reading the offset never
/// feeds back into it). `locked` (search mode) pins the bar open: it scrolls to
/// the fully-revealed position and suspends the snap, but scrolling itself
/// stays live so the results can be browsed and the keyboard scroll-dismissed.
/// On release the scroll snaps to fully hidden or fully revealed.
struct CollapsibleScroll<Content: View>: UIViewControllerRepresentable {
    var topInset: CGFloat
    var bottomInset: CGFloat
    var revealHeight: CGFloat
    var locked: Bool
    var onScroll: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> ScrollHost {
        let host = ScrollHost()
        host.configure(topInset: topInset, bottomInset: bottomInset,
                       revealHeight: revealHeight, locked: locked,
                       onScroll: onScroll, content: content())
        return host
    }

    func updateUIViewController(_ host: ScrollHost, context: Context) {
        host.configure(topInset: topInset, bottomInset: bottomInset,
                       revealHeight: revealHeight, locked: locked,
                       onScroll: onScroll, content: content())
    }
}

/// Hosts the scroll view and its SwiftUI content, and owns the snap + lock
/// behavior. Kept deliberately small: it reports the offset and positions the
/// content; the reveal *visuals* live in SwiftUI (`HomeView`).
final class ScrollHost: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var onScroll: ((CGFloat) -> Void)?
    private var topInset: CGFloat = 0
    private var revealHeight: CGFloat = 0
    private var locked = false
    private var needsInitialOffset = true

    /// Scroll positions: `top == 0` fully revealed, `top == revealHeight` hidden
    /// (`top` is `contentOffset.y + contentInset.top`, negative when overscrolling).
    private var hiddenOffsetY: CGFloat { -topInset + revealHeight }
    private var revealedOffsetY: CGFloat { -topInset }

    /// The lowest offset the content can rest at after any bounce settles;
    /// short content rests at the fully-revealed position itself.
    private var maxRestOffsetY: CGFloat {
        max(scrollView.contentSize.height + scrollView.contentInset.bottom
                - scrollView.bounds.height,
            revealedOffsetY)
    }

    /// Whether the content is tall enough for the bar to rest tucked away.
    /// When it isn't, the bar simply stays revealed (search always reachable on
    /// a lightly stocked fridge) and the snap logic stands down — UIKit's own
    /// bounce is the only sensible rest behavior.
    private var canRestHidden: Bool { maxRestOffsetY >= hiddenOffsetY }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .onDrag
        // Without this, content shorter than the viewport has no scrollable
        // range at all: the pan gesture never engages, the screen feels frozen,
        // and the pull-to-reveal search bar is unreachable. True keeps the pan
        // (and the reveal) alive at any inventory size.
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .clear
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosting.view)
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hosting.view.widthAnchor.constraint(equalTo: frame.widthAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    func configure(topInset: CGFloat, bottomInset: CGFloat, revealHeight: CGFloat,
                   locked: Bool, onScroll: @escaping (CGFloat) -> Void, content: some View) {
        self.onScroll = onScroll
        self.revealHeight = revealHeight
        hosting.rootView = AnyView(content)
        scrollView.contentInset = UIEdgeInsets(top: topInset, left: 0,
                                               bottom: bottomInset, right: 0)
        self.topInset = topInset

        // Focusing pins the bar fully open; releasing focus leaves it as-is.
        // Scrolling stays enabled throughout: disabling it froze the whole list
        // for the duration of search mode (results couldn't be browsed and the
        // .onDrag keyboard dismissal never fired). The bar can't collapse while
        // locked anyway — SearchBarView pins its progress to 1 in search mode.
        if locked, !self.locked {
            scrollView.setContentOffset(CGPoint(x: 0, y: revealedOffsetY), animated: true)
        }
        self.locked = locked
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Start hidden — the reveal spacer scrolled up under the header — or,
        // when the content is too short to rest there, fully revealed (which is
        // also every short fridge's natural rest position, so nothing drifts).
        // Must wait for a real content size or the offset is clamped back.
        if needsInitialOffset, scrollView.contentSize.height > 0 {
            needsInitialOffset = false
            scrollView.contentOffset.y = canRestHidden ? hiddenOffsetY : revealedOffsetY
        }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        onScroll?(sv.contentOffset.y + sv.contentInset.top)
    }

    // Snap the bar fully open or shut on release, so it never rests half-revealed.
    func scrollViewWillEndDragging(_ sv: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !locked, canRestHidden else { return }
        let projectedTop = targetContentOffset.pointee.y + sv.contentInset.top
        // Only snap within the reveal band; past it, let the list scroll freely.
        guard projectedTop < revealHeight else { return }
        let open = velocity.y < -0.1 || (velocity.y <= 0.1 && projectedTop < revealHeight / 2)
        targetContentOffset.pointee.y = open ? revealedOffsetY : hiddenOffsetY
    }

    // Safety nets for a slow release (no deceleration) or an inexact landing:
    // guarantee the bar comes to rest fully open or fully closed.
    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snapIfInBand(sv) }
    }
    func scrollViewDidEndDecelerating(_ sv: UIScrollView) { snapIfInBand(sv) }
    func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) { snapIfInBand(sv) }

    private func snapIfInBand(_ sv: UIScrollView) {
        guard !locked, canRestHidden else { return }
        let top = sv.contentOffset.y + sv.contentInset.top
        guard top > 0.5, top < revealHeight - 0.5 else { return }
        let target = top < revealHeight / 2 ? revealedOffsetY : hiddenOffsetY
        sv.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}
