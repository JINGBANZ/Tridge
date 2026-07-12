import SwiftUI
import SwiftData
import PhotosUI

/// The whole app on one screen: frameless item grid on the chilled background,
/// one scan button, drag-to-consume.
struct HomeView: View {
    private static let gridLayout = Array(
        repeating: GridItem(.flexible(), spacing: AppTheme.gridColumnGap),
        count: AppTheme.gridColumns
    )

    /// Overscroll (pt) past the top that expands the bar, and the scroll-up
    /// drift past which an idle, empty bar collapses again.
    private static let searchRevealPull: CGFloat = 44
    private static let searchHideDrift: CGFloat = 12

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("notificationHour") private var notificationHour = 9

    // Soonest-expiring first puts expired items at the very top.
    @Query(filter: #Predicate<FridgeItem> { $0.statusRaw == "active" },
           sort: \FridgeItem.expiryDate)
    private var items: [FridgeItem]

    @State private var scanFlow = ScanFlowModel()
    @State private var selectedItem: FridgeItem?
    @State private var showSettings = false
    @State private var showManualAdd = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var searchText = ""
    /// Search "mode": true from first focus until Cancel is tapped — distinct
    /// from `searchFocused` (the keyboard) so scrolling the results can dismiss
    /// the keyboard without leaving search mode, as in Apple Music.
    @State private var searchActive = false
    /// Pull-to-reveal: the capsule is hidden at rest and expands (spring) when
    /// the grid is overscrolled past the threshold, collapsing again on
    /// scroll-up. `searchRevealed` is the latched state; `revealAmount` (0…1) is
    /// its animated companion that drives the bar's height and the reserved
    /// grid space so both move together.
    @State private var searchRevealed = false
    @State private var revealAmount: CGFloat = 0
    @State private var scrolledIntoList = false
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

    // Drag-to-consume state
    @State private var draggedItem: FridgeItem?
    @State private var dragLocation: CGPoint = .zero
    @State private var dragScale: CGFloat = 1.3
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
                scrollingContent
                headerOccluder
                searchBarOverlay
                headerBar
            }

            bottomArea
            draggedGhost

            if scanFlow.phase == .processing {
                ScanProgressView()
                    .transition(.opacity)
            }
        }
        .coordinateSpace(name: "fridge")
        .onPreferenceChange(DropZoneFramesKey.self) { zoneFrames = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: draggedItem == nil)
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
                searchRevealed = false
                revealAmount = 0
                scrolledIntoList = false
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
        }
        .accessibilityLabel(hasActiveFilter ? "Filter (active)" : "Filter")
        .accessibilityIdentifier("home.filterButton")
    }

    // MARK: Search

    /// The capsule search field (item-grouping-search.html §6.2, Apple
    /// Music–style). Lives in `searchBarOverlay`, whose height tracks the pull
    /// so the capsule expands/collapses with the scroll. Focusing slides in the
    /// circular cancel button on the right and, via `searchActive`, fades the
    /// header away.
    private var searchBar: some View {
        HStack(spacing: AppTheme.searchCancelGap) {
            HStack(spacing: AppTheme.searchFieldIconGap) {
                Image(systemName: "magnifyingglass")
                    .font(AppTheme.searchFont)
                    .foregroundStyle(AppTheme.mutedInk)
                TextField("Search your fridge", text: $searchText)
                    .font(AppTheme.searchFont)
                    .foregroundStyle(AppTheme.ink)
                    .tint(AppTheme.brandGreen)
                    .focused($searchFocused)
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
            // Tapping anywhere on the capsule focuses it, as in the system bar.
            .onTapGesture { searchFocused = true }

            if searchActive {
                Button(action: exitSearch) {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchText.isEmpty)
    }

    /// Cancel leaves search mode: drop the keyboard, clear the query, fade the
    /// header back in, and drop the capsule to its revealed rest position (still
    /// shown below the header — scrolling up from here collapses it).
    private func exitSearch() {
        searchFocused = false
        searchText = ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            searchActive = false
            searchRevealed = true
            revealAmount = 1
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

    /// The full-screen scroll region behind the header. A clear spacer in the
    /// top safe-area inset reserves the header band plus the bar's current
    /// height, so the grid sits below it. The reveal fires only on discrete
    /// threshold crossings (Bool observers), never per scroll frame — a
    /// per-frame state write read by this same body loops the layout.
    private var scrollingContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if hasActiveFilter {
                    activeFilterBar
                }
                if visibleItems.isEmpty {
                    noMatchView
                } else {
                    gridBody
                }
            }
            .padding(.bottom, AppTheme.scanButtonClearance)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: headerReserve + insetBarSpace)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // The scroll view fills the screen behind the header, which occludes
        // whatever scrolls under it.
        .ignoresSafeArea(.container, edges: .top)
        // Both observers map the offset to a Bool, so actions fire only on
        // threshold crossings — never per scroll frame (a per-frame state write
        // read by this same body loops the layout). Overscrolling down past the
        // threshold expands the bar; the hide latches at a scroll-phase boundary.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < -Self.searchRevealPull
        } action: { _, pulledDown in
            if pulledDown { setSearchRevealed(true) }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Self.searchHideDrift
        } action: { _, isInList in
            scrolledIntoList = isInList
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if oldPhase == .interacting || newPhase == .idle { hideSearchIfIdle() }
        }
        .onChange(of: searchText) { hideSearchIfIdle() }
        .onChange(of: searchFocused) { _, focused in
            // Focusing enters search mode; blur (e.g. scroll-to-dismiss) keeps
            // search mode until Cancel, matching Apple Music.
            guard focused, !searchActive else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                searchActive = true
            }
        }
    }

    /// Expands the bar with a spring — the overlay height and the reserved grid
    /// space both animate off `revealAmount`, so the bar grows and the grid
    /// slides down together.
    private func setSearchRevealed(_ revealed: Bool) {
        guard searchRevealed != revealed, !searchActive else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            searchRevealed = revealed
            revealAmount = revealed ? 1 : 0
        }
    }

    /// Collapses an idle, empty, unfocused bar the user has scrolled up past.
    private func hideSearchIfIdle() {
        guard scrolledIntoList, searchRevealed, searchText.isEmpty, !searchActive else { return }
        setSearchRevealed(false)
    }

    private var gridBody: some View {
        LazyVGrid(
            columns: Self.gridLayout,
            spacing: AppTheme.gridRowGap
        ) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.persistentModelID) { index, item in
                slot(for: item, index: index)
            }
        }
        .padding(.horizontal, AppTheme.screenMargin)
        .padding(.top, AppTheme.screenMargin)
    }

    /// Height of the clear spacer in the scroll view's top inset — the status
    /// bar + header band, held constant so reading the scroll offset never
    /// feeds back into itself. Focused, it shrinks so the capsule rises to just
    /// below the status bar (the header having faded).
    private var headerReserve: CGFloat {
        searchActive
            ? safeTop + AppTheme.searchFocusTopGap
            : safeTop + headerContentHeight
    }

    /// 0…1 openness of the bar: 1 while focused, else the animated
    /// `revealAmount`. Written only inside `withAnimation` on a latch, so it
    /// interpolates over a finite spring — never a per-frame write that would
    /// loop the layout.
    private var barFraction: CGFloat {
        searchActive ? 1 : revealAmount
    }

    /// Scroll space the grid reserves for the bar, animating in step with the
    /// overlay so the grid slides down as the bar grows.
    private var insetBarSpace: CGFloat {
        AppTheme.searchRevealHeight * barFraction
    }

    // MARK: Search bar overlay

    /// The capsule, drawn above the grid (so items can never overlap it) and
    /// below the header (so it stays clear of it). Its height tracks
    /// `barFraction` — expanding open on a pull, collapsing away on scroll-up.
    /// Being a sibling of the scroll view, resizing it never disturbs the
    /// scroll geometry.
    private var searchBarOverlay: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headerReserve)
            // Laid out at its natural height (`fixedSize`), then clipped to the
            // reveal window — clipping the window (rather than squashing the
            // field toward zero height) keeps layout stable and lets the height
            // animate open/closed.
            searchBar
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: AppTheme.searchRevealHeight * barFraction,
                       alignment: .bottom)
                .clipped()
                .opacity(barFraction)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(.container, edges: .top)
        // Only tappable once fully open, so a partly-revealed bar doesn't eat
        // taps meant for the grid.
        .allowsHitTesting(barFraction >= 0.99)
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

    /// A copy of the chilled background masked to the whole top band — status
    /// bar + header + the bar's current height — painted above the scroll
    /// content and *below* the capsule. Because it renders identically to the
    /// base background, any grid content in that band (e.g. a first row that
    /// momentarily lags the reveal animation) is hidden seamlessly — gradient,
    /// glow, and all — so items can never overlap the bar.
    private var headerOccluder: some View {
        AppTheme.ChillBackground()
            .mask(alignment: .top) {
                Rectangle()
                    .frame(height: headerReserve + insetBarSpace)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private func slot(for item: FridgeItem, index: Int) -> some View {
        GridSlot(
            item: item,
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
                    dragScale = 1.3
                }
                dragLocation = location
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

    @ViewBuilder
    private var draggedGhost: some View {
        if let item = draggedItem, dragLocation != .zero {
            Text(Artwork.artwork(for: item))
                .font(.system(size: AppTheme.artPointSize))
                .scaleEffect(dragScale)
                .rotationEffect(.degrees(-4))
                .shadow(color: .black.opacity(0.4), radius: 9, y: 16)
                .position(dragLocation)
                .allowsHitTesting(false)
        }
    }

    private var hotZone: DropZone? {
        guard draggedItem != nil else { return nil }
        return zoneFrames.first { $0.value.contains(dragLocation) }?.key
    }

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
                dragLocation = CGPoint(x: zoneFrames[zone]?.midX ?? location.x,
                                       y: zoneFrames[zone]?.midY ?? location.y)
                dragScale = 0.15
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                consume(item, into: zone)
                clearDrag()
            }
        }
    }

    private func clearDrag() {
        draggedItem = nil
        dragLocation = .zero
        dragScale = 1.3
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
                DropZoneBar(hotZone: hotZone)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// One tap opens the add menu: scan (camera where it exists, album
    /// anywhere) or type an item in by hand. Still the home screen's single
    /// control — no hidden long-press.
    private var scanButton: some View {
        Menu {
            if DocumentCameraView.isCameraSupported {
                Button {
                    scanFlow.startScan(from: .camera)
                } label: {
                    Label("Scan with camera", systemImage: "doc.viewfinder")
                }
                .accessibilityIdentifier("home.scanMenu.camera")
            }
            Button {
                scanFlow.startScan(from: .photoLibrary)
            } label: {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("home.scanMenu.library")
            Button {
                showManualAdd = true
            } label: {
                Label("Type to add", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("home.scanMenu.manualAdd")
            #if DEBUG
            Button {
                scanFlow.scanSampleReceipt()
            } label: {
                Label("Try sample receipt", systemImage: "testtube.2")
            }
            .accessibilityIdentifier("home.scanMenu.sample")
            Button {
                PreviewData.seed(into: context)
            } label: {
                Label("Seed the App", systemImage: "sparkles")
            }
            .accessibilityIdentifier("home.scanMenu.seed")
            #endif
            Divider()
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("home.scanMenu.cancel")
        } label: {
            Text("🧾")
                .font(.system(size: 25))
                .frame(width: AppTheme.scanButtonSize, height: AppTheme.scanButtonSize)
                .background(
                    LinearGradient(colors: [AppTheme.scanTop, AppTheme.scanBottom],
                                   startPoint: .top, endPoint: .bottom),
                    in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                // Confine the tap target and the menu's highlight platter to the
                // circle — without this the platter fills the square label frame
                // and shows as a rounded square behind the round button on tap.
                .contentShape(Circle())
                .shadow(color: AppTheme.brandGreen.opacity(0.45), radius: 10, y: 8)
        }
        // The menu opens upward; automatic ordering would flip it and put
        // Cancel on top. Fixed order keeps Cancel at the bottom, action-sheet
        // style, nearest the button.
        .menuOrder(.fixed)
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

/// One grid cell, `Equatable`-gated so the closures it carries (which SwiftUI
/// can't diff) don't force a re-evaluation of every cell on each `HomeView`
/// body pass — during a drag, `dragLocation` changes per frame and only the
/// ghost should re-render, not the whole grid. Item *content* changes still
/// propagate: the SwiftData model is `@Observable`-backed, so `ItemSprite`
/// tracks the properties it reads directly, past this gate.
private struct GridSlot: View, Equatable {
    let item: FridgeItem
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
            && lhs.index == rhs.index
            && lhs.popInEnabled == rhs.popInEnabled
            && lhs.opacity == rhs.opacity
    }

    var body: some View {
        ItemSprite(item: item)
            .modifier(PopIn(index: index, enabled: popInEnabled, onFinished: onPopInFinished))
            .opacity(opacity)
            .onTapGesture(perform: onTap)
            .gesture(consumeGesture)
    }

    private var consumeGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("fridge")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                onDragChanged(drag.location)
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    onDragEnded(drag.location)
                } else {
                    onDragEnded(nil)
                }
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
