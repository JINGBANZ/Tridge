import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// The whole app on one screen: frameless item grid on the chilled background,
/// one scan button, drag-to-consume.
struct HomeView: View {
    private static let gridLayout = Array(
        repeating: GridItem(.flexible(), spacing: AppTheme.gridColumnGap),
        count: AppTheme.gridColumns
    )

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("notificationHour") private var notificationHour = 9
    /// Settings → Emoji-free mode: items render as name rows, no art anywhere.
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    // Soonest-expiring first puts expired items at the very top.
    @Query(filter: #Predicate<FridgeItem> { $0.statusRaw == "active" },
           sort: \FridgeItem.expiryDate)
    private var items: [FridgeItem]

    @State private var scanFlow = ScanFlowModel()
    @State private var selectedItem: FridgeItem?
    @State private var showSettings = false
    @State private var showManualAdd = false
    @State private var showAddMenu = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var searchText = ""
    /// Search "mode": true from first focus until Cancel is tapped — distinct
    /// from `searchFocused` (the keyboard) so scrolling the results can dismiss
    /// the keyboard without leaving search mode, as in Apple Music.
    @State private var searchActive = false
    /// The bar's live 0…1 openness, driven continuously by the UIKit scroll
    /// offset. Isolated so scrolling re-renders only the bar overlay + occluder,
    /// never `body` (which hosts the grid).
    @State private var reveal = RevealModel()
    @FocusState private var searchFocused: Bool
    /// Measured so the grid rests just beneath the header and the occluder
    /// covers exactly the status bar + header. Seeded with typical values to
    /// avoid a first-frame jump.
    @State private var safeTop: CGFloat = 59
    @State private var headerContentHeight: CGFloat = 48
    @State private var animatedItemIDs: Set<UUID> = []

    // Filter state: nil = "All" on that axis.
    @State private var filterStorage: StorageLocation?
    @State private var filterCategory: FoodCategory?
    @State private var showFilterSheet = false

    // Drag-to-consume state. The item changes once per drag and may drive
    // `body`; the live position/scale change every frame and live in `drag`
    // (isolated like `RevealModel`) so only the ghost and drop bar re-render.
    @State private var draggedItem: FridgeItem?
    @State private var drag = DragModel()
    @State private var zoneFrames: [DropZone: CGRect] = [:]

    // No NavigationStack: nothing navigates, and a system search drawer is
    // scroll-linked — it resizes the bar area every frame while the grid
    // scrolls, re-laying-out the whole screen. Instead the grid fills the
    // screen behind an opaque header layer; the search capsule is the grid's
    // first scrolling row, so it tucks *under* the header on scroll by plain
    // layout — no per-frame scroll math (Apple Music's Library → Songs search).
    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.ChillBackground()

            if items.isEmpty {
                VStack(spacing: 0) {
                    header
                    EmptyStateView()
                        .padding(.bottom, AppTheme.scanButtonClearance)
                        .accessibilityIdentifier("home.emptyState")
                }
            } else {
                collapsibleGrid
                HeaderOccluderView(reveal: reveal, searchActive: searchActive,
                                   headerReserve: headerReserve)
                SearchBarView(reveal: reveal, searchActive: searchActive,
                              headerReserve: headerReserve, searchText: $searchText,
                              searchFocused: $searchFocused, onCancel: exitSearch)
                headerBar
            }

            bottomArea
            DragGhostView(drag: drag, item: draggedItem, emojiFree: emojiFreeMode)

            if scanFlow.phase == .processing {
                ScanProgressView()
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(DropZoneFramesKey.self) { zoneFrames = $0 }
        .animation(AppTheme.searchSpring, value: draggedItem == nil)
        .sheet(item: $selectedItem) { item in
            ItemDetailSheet(item: item)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: reviewBinding) {
            ReviewSheet(model: scanFlow)
        }
        .sheet(isPresented: $showManualAdd) {
            ManualAddSheet()
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(storage: $filterStorage, category: $filterCategory)
        }
        .fullScreenCover(isPresented: cameraBinding) {
            DocumentCameraView { scanFlow.handleCapture($0) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: photoPickerBinding, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            scanFlow.handlePickedPhoto(item)
        }
        .alert("Scan failed", isPresented: failedBinding, actions: {
            Button("Try Again") { scanFlow.retry() }
            Button("Cancel", role: .cancel) { scanFlow.reset() }
        }, message: {
            Text("\(failureMessage)\n\nDetails were logged — Settings → Copy diagnostics.")
        })
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updateBadge() }
        }
        .onChange(of: items.count) { updateBadge() }
        .onChange(of: items.isEmpty) { _, empty in
            // Filters and search don't outlive the inventory: the last item
            // leaving also removes the search bar, so nothing could clear a
            // stale filter or query afterward.
            if empty {
                clearFilters()
                searchFocused = false
                searchText = ""
                searchActive = false
                reveal.progress = 0
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // Focusing enters search mode (pins the bar open, fades the header);
            // Cancel leaves it. Scrolling stays live throughout — dragging the
            // results dismisses the keyboard (keyboardDismissMode .onDrag)
            // without leaving search mode, as in Apple Music.
            guard focused, !searchActive else { return }
            withAnimation(AppTheme.searchSpring) {
                searchActive = true
            }
        }
    }

    // MARK: Filtering

    private var hasActiveFilter: Bool {
        filterStorage != nil || filterCategory != nil
    }

    private var filteredItems: [FridgeItem] {
        items.filter { item in
            (filterStorage == nil || item.storage == filterStorage)
                && (filterCategory == nil || item.foodCategory == filterCategory)
        }
    }

    private func clearFilters() {
        filterStorage = nil
        filterCategory = nil
    }

    /// Removable tags naming the active filters — filter state stays visible
    /// while the sheet is closed.
    private var activeFilterBar: some View {
        HStack(spacing: AppTheme.filterChipSpacing) {
            if let storage = filterStorage {
                filterTag(storage.label) { filterStorage = nil }
                    .accessibilityIdentifier("home.filterTag.storage")
            }
            if let category = filterCategory {
                filterTag(category.label) { filterCategory = nil }
                    .accessibilityIdentifier("home.filterTag.category")
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.filterBarPadding.h)
        .padding(.top, AppTheme.filterBarPadding.top)
    }

    private func filterTag(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: AppTheme.filterTagSpacing) {
                Text(label)
                    .font(AppTheme.filterChipFont)
                Image(systemName: "xmark")
                    .font(AppTheme.filterTagXFont)
                    .opacity(AppTheme.filterTagDismissOpacity)
            }
            .foregroundStyle(AppTheme.chipSelectedLabel)
            .padding(.horizontal, AppTheme.filterChipPadding.h)
            .padding(.vertical, AppTheme.filterChipPadding.v)
            .background(AppTheme.brandGreen, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label) filter")
    }

    private var noMatchView: some View {
        VStack(spacing: AppTheme.ghostSpacing) {
            Text("🕳️")
                .font(AppTheme.ghostArtFont)
                .opacity(AppTheme.ghostArtOpacity)
            Text(searchText.isEmpty
                 ? "Nothing matches — remove a filter"
                 : "No items match your search")
                .font(AppTheme.ghostTextFont)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppTheme.noMatchTopPad)
        .padding(.bottom, AppTheme.scanButtonClearance)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.noMatch")
    }

    // MARK: Header

    /// The header counts units, not rows — a ×3 milk is three items — and
    /// follows the active filter.
    private var unitCount: Int {
        filteredItems.reduce(0) { $0 + $1.quantity }
    }

    private var header: some View {
        HStack {
            Text("Tridge")
                .font(AppTheme.titleFont)
                .foregroundStyle(AppTheme.ink)
                .accessibilityIdentifier("home.title")
            Spacer()
            HStack(spacing: 10) {
                Text("\(unitCount) item\(unitCount == 1 ? "" : "s")")
                    .font(AppTheme.countFont)
                    .foregroundStyle(AppTheme.mutedInk)
                    .accessibilityIdentifier("home.itemCount")
                if !items.isEmpty {
                    filterButton
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.headerGlyphSize))
                        .foregroundStyle(AppTheme.mutedInk)
                        .headerHitTarget()
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settingsButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Bare glyph at the gear's visual weight; tints green with a dot while a
    /// filter is active. Absent entirely on an empty fridge.
    private var filterButton: some View {
        Button {
            showFilterSheet = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: AppTheme.headerGlyphSize,
                              weight: hasActiveFilter ? .semibold : .regular))
                .foregroundStyle(hasActiveFilter ? AppTheme.brandGreen : AppTheme.mutedInk)
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilter {
                        Circle()
                            .fill(AppTheme.brandGreen)
                            .frame(width: AppTheme.filterDotSize, height: AppTheme.filterDotSize)
                            .offset(x: AppTheme.filterDotOffset.x, y: AppTheme.filterDotOffset.y)
                    }
                }
                .headerHitTarget()
        }
        .accessibilityLabel(hasActiveFilter ? "Filter (active)" : "Filter")
        .accessibilityIdentifier("home.filterButton")
    }

    // MARK: Search

    /// Cancel leaves search mode: drop the keyboard, clear the query, and fade
    /// the header back in. The capsule stays at its current (revealed) openness
    /// — scrolling up from here collapses it.
    private func exitSearch() {
        searchFocused = false
        searchText = ""
        withAnimation(AppTheme.searchSpring) {
            searchActive = false
        }
    }

    // MARK: Grid

    /// The grid filtered by the search field on top of the active Storage /
    /// Food Category filters; expiry order is preserved. Matching is
    /// diacritic-blind via the stored normalized key.
    private var visibleItems: [FridgeItem] {
        let query = NameKey.normalize(searchText)
        guard !query.isEmpty else { return filteredItems }
        return filteredItems.filter {
            NameSearch.tier(query: query, candidate: $0.normalizedName) != nil
        }
    }

    /// The scrollable grid, hosted in a `UIScrollView` (`CollapsibleScroll`) so
    /// the search bar can expand/collapse continuously with the scroll without a
    /// SwiftUI layout cycle. The content leads with a transparent spacer the
    /// height of the bar: it scrolls naturally with the grid, so the grid rises
    /// to meet the bar as it collapses (no gap). The visible capsule is drawn by
    /// `SearchBarView`, sized from the live scroll offset published to `reveal`.
    private var collapsibleGrid: some View {
        CollapsibleScroll(
            topInset: headerReserve,
            bottomInset: AppTheme.scanButtonClearance,
            revealHeight: AppTheme.searchRevealHeight,
            locked: searchActive,
            onScroll: { top in
                let clamped = min(max(top, 0), AppTheme.searchRevealHeight)
                let progress = 1 - clamped / AppTheme.searchRevealHeight
                // Same-value writes still notify @Observable observers, so
                // skip them — otherwise every frame of ordinary scrolling
                // (progress pinned at 0) re-renders the bar and occluder.
                if reveal.progress != progress { reveal.progress = progress }
            }
        ) {
            // Evaluated once per body pass; reading `visibleItems` in each
            // branch would re-filter the inventory per access.
            let visible = visibleItems
            VStack(spacing: 0) {
                Color.clear.frame(height: AppTheme.searchRevealHeight)
                if hasActiveFilter {
                    activeFilterBar
                }
                if visible.isEmpty {
                    noMatchView
                } else if emojiFreeMode {
                    listBody(visible)
                } else {
                    gridBody(visible)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func gridBody(_ visible: [FridgeItem]) -> some View {
        LazyVGrid(
            columns: Self.gridLayout,
            spacing: AppTheme.gridRowGap
        ) {
            ForEach(Array(visible.enumerated()), id: \.element.persistentModelID) { index, item in
                slot(for: item, index: index)
            }
        }
        .padding(.horizontal, AppTheme.screenMargin)
        .padding(.top, AppTheme.screenMargin)
    }

    /// Emoji-free mode's stand-in for the grid: one name row per item, same
    /// order, same tap-to-edit and drag-to-consume gestures.
    private func listBody(_ visible: [FridgeItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.persistentModelID) { index, item in
                slot(for: item, index: index)
            }
        }
        .padding(.top, AppTheme.screenMargin)
    }

    /// Distance from the screen top to the bar (and the grid's reveal spacer):
    /// status bar + header at rest; focused, the header has faded so the capsule
    /// rises to just below the status bar. No scroll dependency, so `body` never
    /// re-renders mid-scroll.
    private var headerReserve: CGFloat {
        searchActive
            ? safeTop + AppTheme.searchFocusTopGap
            : safeTop + headerContentHeight
    }

    // MARK: Header overlay

    /// The pinned header, drawn above the scroll content so the search capsule
    /// tucks under it. Measures its own height (and the safe-area top) so the
    /// grid can park just beneath it. Fades away in search mode.
    private var headerBar: some View {
        header
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                safeTop = rect.minY
                headerContentHeight = rect.height
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(searchActive ? 0 : 1)
            .allowsHitTesting(!searchActive)
    }

    private func slot(for item: FridgeItem, index: Int) -> some View {
        GridSlot(
            item: item,
            emojiFree: emojiFreeMode,
            index: index,
            popInEnabled: !reduceMotion
                && index < AppTheme.popInItemLimit
                && !animatedItemIDs.contains(item.id),
            opacity: slotOpacity(for: item),
            onPopInFinished: { animatedItemIDs.insert(item.id) },
            onTap: { selectedItem = item },
            onDragChanged: { location in
                if draggedItem == nil {
                    draggedItem = item
                    drag.scale = 1.3
                }
                drag.location = location
            },
            onDragEnded: { location in
                if let location { endDrag(at: location) } else { clearDrag() }
            }
        )
        .equatable()
    }

    private func slotOpacity(for item: FridgeItem) -> Double {
        guard draggedItem != nil else { return 1 }
        return item === draggedItem ? 0.25 : 0.4
    }

    // MARK: Drag to consume

    private func endDrag(at location: CGPoint) {
        guard let item = draggedItem else { return }
        guard let zone = zoneFrames.first(where: { $0.value.contains(location) })?.key else {
            clearDrag() // released outside a zone cancels
            return
        }
        Haptics.consume()
        if reduceMotion {
            consume(item, into: zone)
            clearDrag()
        } else {
            // Shrink the ghost into the zone before the grid updates.
            withAnimation(.easeIn(duration: 0.2)) {
                drag.location = CGPoint(x: zoneFrames[zone]?.midX ?? location.x,
                                        y: zoneFrames[zone]?.midY ?? location.y)
                drag.scale = 0.15
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                consume(item, into: zone)
                clearDrag()
            }
        }
    }

    private func clearDrag() {
        draggedItem = nil
        drag.location = .zero
        drag.scale = 1.3
    }

    /// ×N items decrement one unit and stay until the count hits zero.
    private func consume(_ item: FridgeItem, into zone: DropZone) {
        if item.quantity > 1 {
            item.quantity -= 1
        } else {
            item.status = zone == .ate ? .eaten : .tossed
            item.consumedDate = Date()
            NotificationService.cancel(for: item.id)
        }
        updateBadge()
    }

    // MARK: Bottom area

    private var bottomArea: some View {
        VStack {
            Spacer()
            if draggedItem == nil {
                scanButton
                    .padding(.bottom, 10)
                    .transition(.opacity)
            } else {
                DropZoneBarHost(drag: drag, zoneFrames: zoneFrames)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// One tap opens the add menu: scan (camera where it exists, album
    /// anywhere) or type an item in by hand. Still the home screen's single
    /// control — no hidden long-press. An action sheet rather than a `Menu`:
    /// menu rows are always leading-aligned, and the owner wants Cancel
    /// centered, action-sheet style.
    private var scanButton: some View {
        Button {
            showAddMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(AppTheme.chipSelectedLabel)
                .frame(width: AppTheme.scanButtonSize, height: AppTheme.scanButtonSize)
                .background(
                    LinearGradient(colors: [AppTheme.scanTop, AppTheme.scanBottom],
                                   startPoint: .top, endPoint: .bottom),
                    in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                // Confine the tap target to the circle, not the square label frame.
                .contentShape(Circle())
                .shadow(color: AppTheme.brandGreen.opacity(0.45), radius: 10, y: 8)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Add items", isPresented: $showAddMenu) {
            if DocumentCameraView.isCameraSupported {
                Button("Scan with camera") { scanFlow.startScan(from: .camera) }
                    .accessibilityIdentifier("home.scanMenu.camera")
            }
            Button("Choose from library") { scanFlow.startScan(from: .photoLibrary) }
                .accessibilityIdentifier("home.scanMenu.library")
            Button("Type to add") { showManualAdd = true }
                .accessibilityIdentifier("home.scanMenu.manualAdd")
            #if DEBUG
            Button("Try sample receipt") { scanFlow.scanSampleReceipt() }
                .accessibilityIdentifier("home.scanMenu.sample")
            Button("Seed the App") { PreviewData.seed(into: context) }
                .accessibilityIdentifier("home.scanMenu.seed")
            #endif
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("home.scanMenu.cancel")
        }
        .accessibilityLabel("Add items")
        .accessibilityIdentifier("home.scanButton")
    }

    // MARK: Scan flow plumbing

    private var cameraBinding: Binding<Bool> {
        Binding(get: { scanFlow.phase == .camera },
                set: { if !$0 && scanFlow.phase == .camera { scanFlow.reset() } })
    }

    private var photoPickerBinding: Binding<Bool> {
        // Dismissal precedes the async selection callback, so only flip the
        // phase back — a full reset would race the incoming photo.
        Binding(get: { scanFlow.phase == .photoPicker },
                set: { if !$0 && scanFlow.phase == .photoPicker { scanFlow.phase = .idle } })
    }

    private var reviewBinding: Binding<Bool> {
        Binding(get: { scanFlow.phase == .review },
                set: { if !$0 && scanFlow.phase == .review { scanFlow.reset() } })
    }

    private var failedBinding: Binding<Bool> {
        Binding(get: {
            if case .failed = scanFlow.phase { return true }
            return false
        }, set: { if !$0, case .failed = scanFlow.phase { scanFlow.reset() } })
    }

    private var failureMessage: String {
        if case .failed(let message) = scanFlow.phase { return message }
        return ""
    }

    private func updateBadge() {
        NotificationService.updateBadge(expiredCount: items.filter(\.isExpired).count)
    }
}

private extension View {
    /// The bare header glyphs are well under the 44pt hit minimum (the filter
    /// lines are ~15pt tall), so taps beside them fell through. Pad the
    /// tappable area out, then pull the layout back in so the header keeps its
    /// glyph-sized spacing — padding never clips, so the padded shape still
    /// hit-tests.
    func headerHitTarget() -> some View {
        padding(.horizontal, AppTheme.headerButtonHitPad.h)
            .padding(.vertical, AppTheme.headerButtonHitPad.v)
            .contentShape(Rectangle())
            .padding(.horizontal, -AppTheme.headerButtonHitPad.h)
            .padding(.vertical, -AppTheme.headerButtonHitPad.v)
    }
}

/// The live drag position and ghost scale, updated every frame of a
/// drag-to-consume. Isolated in its own observable (like `RevealModel`) so
/// per-frame finger moves re-render only the ghost overlay and the drop-zone
/// bar — never `HomeView`'s body, which would rebuild the whole grid tree.
@Observable
private final class DragModel {
    /// `.zero` means the long-press hasn't produced a live position yet.
    var location: CGPoint = .zero
    var scale: CGFloat = 1.3
}

/// The ghost travelling under the finger — the item's art, or its name in
/// emoji-free mode. Placed on a full-screen layer that ignores the safe area,
/// so `.position` resolves in global coordinates — the same space as the drag
/// location and the drop-zone frames (global so hit-testing keeps working once
/// the grid is hosted in a `UIScrollView`). Its own view so only it re-renders
/// as `drag` changes each frame.
private struct DragGhostView: View {
    let drag: DragModel
    let item: FridgeItem?
    let emojiFree: Bool

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .overlay {
                if let item, drag.location != .zero {
                    ghostArt(for: item)
                        .scaleEffect(drag.scale)
                        .rotationEffect(.degrees(-4))
                        .shadow(color: .black.opacity(0.4), radius: 9, y: 16)
                        .position(drag.location)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func ghostArt(for item: FridgeItem) -> some View {
        if emojiFree {
            Text(item.name)
                .font(AppTheme.listRowNameFont)
                .foregroundStyle(AppTheme.ink)
        } else {
            Text(Artwork.artwork(for: item))
                .font(.system(size: AppTheme.artPointSize))
        }
    }
}

/// Hit-tests the live drag position against the zone frames and feeds the
/// result to `DropZoneBar`. Its own view for the same reason as the ghost:
/// only it re-renders per drag frame.
private struct DropZoneBarHost: View {
    let drag: DragModel
    let zoneFrames: [DropZone: CGRect]

    var body: some View {
        DropZoneBar(hotZone: zoneFrames.first { $0.value.contains(drag.location) }?.key)
    }
}

/// The capsule search field, drawn as an overlay above the grid (so items can
/// never overlap it) and below the header. Its height tracks the live scroll
/// `reveal.progress`, so it expands/collapses continuously with the finger.
/// Kept a separate view so only it re-renders each scroll frame — not
/// `HomeView`'s body, which hosts the grid.
private struct SearchBarView: View {
    let reveal: RevealModel
    let searchActive: Bool
    let headerReserve: CGFloat
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let onCancel: () -> Void

    /// 1 while focused (pinned open); otherwise the live scroll openness.
    private var progress: CGFloat { searchActive ? 1 : reveal.progress }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerReserve)
            // Laid out at natural height (`fixedSize`), then clipped to the
            // reveal window — clipping keeps layout stable while the height
            // tracks the scroll.
            capsule
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: AppTheme.searchRevealHeight * progress, alignment: .bottom)
                .clipped()
                .opacity(progress)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(.container, edges: .top)
        // Only tappable once fully open, so a partly-revealed bar doesn't eat
        // taps meant for the grid.
        .allowsHitTesting(progress >= 0.99)
    }

    private var capsule: some View {
        HStack(spacing: AppTheme.searchCancelGap) {
            HStack(spacing: AppTheme.searchFieldIconGap) {
                Image(systemName: "magnifyingglass")
                    .font(AppTheme.searchFont)
                    .foregroundStyle(AppTheme.mutedInk)
                TextField("Search your fridge", text: $searchText)
                    .font(AppTheme.searchFont)
                    .foregroundStyle(AppTheme.ink)
                    .tint(AppTheme.brandGreen)
                    .focused(searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("home.search.field")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppTheme.searchClearFont)
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("home.search.clearButton")
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, AppTheme.searchFieldPadding.h)
            .padding(.vertical, AppTheme.searchFieldPadding.v)
            .background(AppTheme.searchFieldFill, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { searchFocused.wrappedValue = true }

            if searchActive {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(AppTheme.searchCancelFont)
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(width: AppTheme.searchCancelSize,
                               height: AppTheme.searchCancelSize)
                        .background(AppTheme.searchFieldFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel search")
                .accessibilityIdentifier("home.search.cancelButton")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, AppTheme.screenMargin)
        .padding(.top, AppTheme.searchBarPadding.top)
        .padding(.bottom, AppTheme.searchBarPadding.bottom)
        .animation(AppTheme.searchSpring, value: searchText.isEmpty)
    }
}

/// A copy of the chilled background masked to the whole top band — status bar +
/// header + the bar's current height — painted above the grid and below the
/// capsule. Rendering identically to the base background, it hides any grid
/// content in that band (including a first row that lags the scroll), so items
/// can never overlap the bar. Its own view so it, too, re-renders per scroll
/// frame without touching `HomeView`'s body.
private struct HeaderOccluderView: View {
    let reveal: RevealModel
    let searchActive: Bool
    let headerReserve: CGFloat

    private var progress: CGFloat { searchActive ? 1 : reveal.progress }

    var body: some View {
        AppTheme.ChillBackground()
            .mask(alignment: .top) {
                Rectangle()
                    .frame(height: headerReserve + AppTheme.searchRevealHeight * progress)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

/// One grid cell, `Equatable`-gated so the closures it carries (which SwiftUI
/// can't diff) don't force a re-evaluation of every cell on each `HomeView`
/// body pass — e.g. the passes at drag start/end, or a search keystroke. Item
/// *content* changes still propagate: the SwiftData model is
/// `@Observable`-backed, so `ItemSprite` tracks the properties it reads
/// directly, past this gate.
private struct GridSlot: View, Equatable {
    let item: FridgeItem
    let emojiFree: Bool
    let index: Int
    let popInEnabled: Bool
    let opacity: Double
    let onPopInFinished: () -> Void
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    /// `nil` means the long-press never matured into a drag — cancel.
    let onDragEnded: (CGPoint?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item === rhs.item
            && lhs.emojiFree == rhs.emojiFree
            && lhs.index == rhs.index
            && lhs.popInEnabled == rhs.popInEnabled
            && lhs.opacity == rhs.opacity
    }

    var body: some View {
        Group {
            if emojiFree {
                ItemRow(item: item)
            } else {
                ItemSprite(item: item)
            }
        }
        .modifier(PopIn(index: index, enabled: popInEnabled, onFinished: onPopInFinished))
        .opacity(opacity)
        .onTapGesture(perform: onTap)
        .gesture(ConsumeGesture(onChanged: onDragChanged, onEnded: onDragEnded))
    }
}

/// A UIKit long press explicitly allowed to recognize beside the hosting
/// scroll view's pan. SwiftUI's sequenced long-press/drag gesture cancelled the
/// pan when it matured, making slow grid scrolling rebound and letting
/// full-width emoji-free rows block scrolling entirely.
private struct ConsumeGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.3
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer,
                                         context: Context) {
        let location = context.converter.location(in: .global)
        switch recognizer.state {
        case .began, .changed:
            onChanged(location)
        case .ended:
            onEnded(location)
        case .cancelled:
            onEnded(nil)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer)
            -> Bool {
            true
        }
    }
}

/// Staggered pop-in on load: scale 0.7 → 1 spring, 0.03s per item; disabled
/// under Reduce Motion.
private struct PopIn: ViewModifier {
    let index: Int
    let enabled: Bool
    let onFinished: () -> Void
    @State private var shown = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .scaleEffect(shown ? 1 : AppTheme.popInStartScale)
                .opacity(shown ? 1 : 0)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.65)
                        .delay(Double(index) * AppTheme.popInDelayPerItem)) {
                        shown = true
                    }
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 0.5 + Double(index) * AppTheme.popInDelayPerItem,
                        execute: onFinished)
                }
        } else {
            // Lazy grid cells appear during scrolling. Leaving them unmodified
            // keeps transforms and delayed springs out of the scroll path.
            content
        }
    }
}

#if DEBUG
#Preview {
    HomeView()
        .modelContainer(PreviewData.container)
}
#endif
