import SwiftUI
import PhotosUI
import UIKit

/// The whole app on one screen: frameless item grid on the chilled background,
/// one scan button, drag-to-consume.
///
/// Everything it renders is a value snapshot of the Active Household, and every
/// change it makes is a repository command. It holds no managed object and no
/// model context, so nothing on screen can outlive the account that produced it.
struct HomeView: View {
    private static let gridLayout = Array(
        repeating: GridItem(.flexible(), spacing: AppTheme.gridColumnGap),
        count: AppTheme.gridColumns
    )

    let session: HouseholdSession
    let coordinator: AccountSessionCoordinator

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Settings → Emoji-free mode: items render as name rows, no art anywhere.
    @AppStorage("emojiFreeMode") private var emojiFreeMode = false

    @State private var scanFlow = ScanFlowModel()
    @State private var selectedItem: InventoryItemSnapshot?
    @State private var showSettings = false
    @State private var manualAdd: ManualAddRequest?
    @State private var showAddMenu = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var searchText = ""
    @State private var animatedItemIDs: Set<UUID> = []
    /// Re-read when the app comes forward, so a fridge left open overnight
    /// grades its urgency against the right day.
    @State private var today = InventoryDay.today()

    // Filter state: nil = "All" on that axis.
    @State private var filterStorage: StorageLocation?
    @State private var filterCategory: FoodCategory?
    @State private var showFilterSheet = false

    // Drag-to-consume state. The item changes once per drag and may drive
    // `body`; the live position/scale change every frame and live in `drag`
    // so only the ghost and drop bar re-render.
    @State private var draggedItem: InventoryItemSnapshot?
    @State private var drag = DragModel()
    @State private var zoneFrames: [DropZone: CGRect] = [:]

    private var items: [InventoryItemSnapshot] { session.items }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppTheme.ChillBackground()

                if items.isEmpty {
                    EmptyStateView()
                        .padding(.bottom, AppTheme.scanButtonClearance)
                        .accessibilityIdentifier("home.emptyState")
                } else {
                    inventoryScroll
                }

                bottomArea
                DragGhostView(drag: drag, item: draggedItem, emojiFree: emojiFreeMode)

                if scanFlow.phase == .processing {
                    ScanProgressView()
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: HomeDragCoordinateSpace.name)
            .modifier(NativeSearchModifier(isEnabled: !items.isEmpty, text: $searchText))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { homeToolbar }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(AppTheme.brandGreen)
        .onPreferenceChange(DropZoneFramesKey.self) { zoneFrames = $0 }
        .animation(AppTheme.dragSpring, value: draggedItem == nil)
        .sheet(item: $selectedItem) { item in
            ItemDetailSheet(item: item, session: session, today: today,
                            onAddAsNew: { manualAdd = ManualAddRequest(prefill: $0) })
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session, coordinator: coordinator)
        }
        .sheet(isPresented: reviewBinding) {
            ReviewSheet(model: scanFlow, session: session)
        }
        .sheet(item: $manualAdd) { request in
            ManualAddSheet(session: session, prefill: request.prefill)
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
        // A command the user started from Home itself — a drag-to-consume —
        // has no sheet of its own to report into.
        .alert("Couldn't save", isPresented: homeFailureBinding, actions: {
            Button("OK", role: .cancel) { session.clearFailure() }
        }, message: {
            Text(session.lastFailure?.message ?? "")
        })
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            today = InventoryDay.today()
            session.refreshReminders()
        }
        .onChange(of: items.isEmpty) { _, empty in
            // Filters and search don't outlive the inventory: the last item
            // leaving also removes the search bar, so nothing could clear a
            // stale filter or query afterward.
            if empty {
                clearFilters()
                searchText = ""
            }
        }
    }

    // MARK: Filtering

    private var hasActiveFilter: Bool {
        filterStorage != nil || filterCategory != nil
    }

    private var filteredItems: [InventoryItemSnapshot] {
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
    private var unitCount: Int64 {
        // Quantities are unbounded positive whole numbers (ADR 0004), so the
        // running total is reported rather than trapped if it ever leaves the
        // representable range.
        filteredItems.reduce(Int64(0)) { total, item in
            total.addingReportingOverflow(item.quantity).partialValue
        }
    }

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                homeTitle
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                homeTitle
            }
        }
#else
        ToolbarItem(placement: .topBarLeading) {
            homeTitle
        }
#endif
        ToolbarItemGroup(placement: .topBarTrailing) {
            Text("\(unitCount) item\(unitCount == 1 ? "" : "s")")
                .font(AppTheme.countFont)
                .foregroundStyle(AppTheme.mutedInk)
                .padding(.leading, AppTheme.headerCountLeadingInset)
                .accessibilityIdentifier("home.itemCount")
            if !items.isEmpty {
                filterButton
            }
            settingsButton
        }
    }

    private var homeTitle: some View {
        Text("Tridge")
            .font(AppTheme.titleFont)
            .foregroundStyle(AppTheme.ink)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.title")
    }

    private var settingsButton: some View {
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

    // MARK: Grid

    /// The grid filtered by the search field on top of the active Storage /
    /// Food Category filters; expiry order is preserved. Matching is
    /// diacritic-blind via the stored normalized key.
    private var visibleItems: [InventoryItemSnapshot] {
        let query = NameKey.normalize(searchText)
        guard !query.isEmpty else { return filteredItems }
        return filteredItems.filter {
            NameSearch.tier(query: query, candidate: $0.normalizedName) != nil
        }
    }

    /// The native navigation controller owns the search drawer and coordinates
    /// its collapse directly with this scroll view. Keeping the grid in the same
    /// SwiftUI hierarchy avoids a second scroll offset or per-frame state update.
    private var inventoryScroll: some View {
        ScrollView {
            let visible = visibleItems
            VStack(spacing: 0) {
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
            .frame(maxWidth: .infinity)
            .padding(.bottom, AppTheme.scanButtonClearance)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private func gridBody(_ visible: [InventoryItemSnapshot]) -> some View {
        LazyVGrid(
            columns: Self.gridLayout,
            spacing: AppTheme.gridRowGap
        ) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                slot(for: item, index: index)
            }
        }
        .padding(.horizontal, AppTheme.screenMargin)
        .padding(.top, AppTheme.screenMargin)
    }

    /// Emoji-free mode's stand-in for the grid: one name row per item, same
    /// order, same tap-to-edit and drag-to-consume gestures.
    private func listBody(_ visible: [InventoryItemSnapshot]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                slot(for: item, index: index)
            }
        }
        .padding(.top, AppTheme.screenMargin)
    }

    private func slot(for item: InventoryItemSnapshot, index: Int) -> some View {
        GridSlot(
            item: item,
            today: today,
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

    private func slotOpacity(for item: InventoryItemSnapshot) -> Double {
        guard let draggedItem else { return 1 }
        return item.id == draggedItem.id ? 0.25 : 0.4
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

    /// One unit leaves the logical item. ×N rows stay until the projection
    /// reaches zero; nothing is decremented in place, so a member consuming the
    /// same item offline still composes.
    private func consume(_ item: InventoryItemSnapshot, into zone: DropZone) {
        Task {
            if zone == .ate {
                await session.eatOne(item.id)
            } else {
                await session.tossOne(item.id)
            }
        }
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
            Button("Type to add") { manualAdd = ManualAddRequest(prefill: nil) }
                .accessibilityIdentifier("home.scanMenu.manualAdd")
            #if DEBUG
            Button("Try sample receipt") { scanFlow.scanSampleReceipt() }
                .accessibilityIdentifier("home.scanMenu.sample")
            Button("Seed the App") { seedDebugInventory() }
                .accessibilityIdentifier("home.scanMenu.seed")
            #endif
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("home.scanMenu.cancel")
        }
        .accessibilityLabel("Add items")
        .accessibilityIdentifier("home.scanButton")
    }

    #if DEBUG
    /// The debug seed is an ordinary multirow confirmation, so it exercises the
    /// same repository path a receipt does instead of writing rows the projector
    /// never saw created.
    private func seedDebugInventory() {
        Task { await session.addReviewedRows(PreviewData.seedPurchases(today: today)) }
    }
    #endif

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

    /// Only failures with no sheet of their own reach Home's alert: the detail,
    /// add, review, and settings sheets each keep their draft open and report
    /// there. An alert raised here while one of them is up would not be
    /// presented at all, so the list has to name every sheet that reports.
    private var homeFailureBinding: Binding<Bool> {
        Binding(get: {
            session.lastFailure != nil && selectedItem == nil && manualAdd == nil
                && !showSettings && scanFlow.phase != .review
        }, set: { if !$0 { session.clearFailure() } })
    }

    private var failureMessage: String {
        if case .failed(let message) = scanFlow.phase { return message }
        return ""
    }
}

/// A manual-add presentation, optionally prefilled. Identifiable so the sheet
/// is rebuilt for each request rather than reusing the previous draft.
struct ManualAddRequest: Identifiable {
    let id = UUID()
    let prefill: ManualAddPrefill?
}

/// The live drag position and ghost scale, updated every frame of a
/// drag-to-consume. Isolated in its own observable so per-frame finger moves
/// re-render only the ghost overlay and the drop-zone bar — never `HomeView`'s
/// body, which would rebuild the whole grid tree.
@Observable
private final class DragModel {
    /// `.zero` means the long-press hasn't produced a live position yet.
    var location: CGPoint = .zero
    var scale: CGFloat = 1.3
}

/// The ghost travelling under the finger — the item's art, or its name in
/// emoji-free mode. Its parent fills the named home drag coordinate space, so
/// `.position` uses the same origin as the gesture and drop-zone frames. Its
/// own view means only it re-renders as `drag` changes each frame.
private struct DragGhostView: View {
    let drag: DragModel
    let item: InventoryItemSnapshot?
    let emojiFree: Bool

    var body: some View {
        Color.clear
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
    private func ghostArt(for item: InventoryItemSnapshot) -> some View {
        if emojiFree {
            Text(item.name)
                .font(AppTheme.listRowNameFont)
                .foregroundStyle(AppTheme.ink)
        } else {
            Text(Artwork.emoji(forKey: item.artKey))
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

/// Adds native navigation search only while inventory exists. The modifier is
/// conditional because an empty fridge deliberately has no search UI.
private struct NativeSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search your fridge"
            )
        } else {
            content
        }
    }
}

/// One grid cell, `Equatable`-gated so the closures it carries (which SwiftUI
/// can't diff) don't force a re-evaluation of every cell on each `HomeView`
/// body pass — e.g. the passes at drag start/end, or a search keystroke. The
/// item is now an immutable snapshot, so comparing it by value is exactly the
/// right gate: a projection that changed the row rebuilds it, and one that did
/// not cannot.
private struct GridSlot: View, Equatable {
    let item: InventoryItemSnapshot
    let today: InventoryDay
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
        lhs.item == rhs.item
            && lhs.today == rhs.today
            && lhs.emojiFree == rhs.emojiFree
            && lhs.index == rhs.index
            && lhs.popInEnabled == rhs.popInEnabled
            && lhs.opacity == rhs.opacity
    }

    var body: some View {
        Group {
            if emojiFree {
                ItemRow(item: item, today: today)
            } else {
                ItemSprite(item: item, today: today)
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
        let location = context.converter.location(
            in: .named(HomeDragCoordinateSpace.name)
        )
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
