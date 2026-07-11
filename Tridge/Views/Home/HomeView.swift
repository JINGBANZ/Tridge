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

    var body: some View {
        // The stack exists only to host the pull-down search field; its bar
        // stays invisible so the home screen keeps its single-control face.
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        // The outer host lets the navigation drawer keep search hidden until
        // the user deliberately pulls down on the inventory.
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search your fridge")
    }

    private var content: some View {
        ZStack {
            AppTheme.ChillBackground()

            VStack(spacing: 0) {
                header
                if items.isEmpty {
                    EmptyStateView()
                        .padding(.bottom, AppTheme.scanButtonSize + 40)
                } else {
                    if hasActiveFilter {
                        activeFilterBar
                    }
                    if filteredItems.isEmpty {
                        noMatchView
                    } else {
                        grid
                    }
                }
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
            // Filters don't outlive the inventory: the last item leaving also
            // hides the filter button, so nothing could remove a stale filter.
            if empty { clearFilters() }
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
            }
            if let category = filterCategory {
                filterTag(category.label) { filterCategory = nil }
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
                    .opacity(0.75)
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
                .opacity(0.5)
            Text("Nothing matches — remove a filter")
                .font(AppTheme.ghostTextFont)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, AppTheme.scanButtonSize + 40)
        .accessibilityElement(children: .combine)
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
            Spacer()
            HStack(spacing: 10) {
                Text("\(unitCount) item\(unitCount == 1 ? "" : "s")")
                    .font(AppTheme.countFont)
                    .foregroundStyle(AppTheme.mutedInk)
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

    private var grid: some View {
        ScrollView {
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
            .padding(.bottom, AppTheme.scanButtonSize + 40)
        }
        .scrollIndicators(.hidden)
    }

    private func slot(for item: FridgeItem, index: Int) -> some View {
        ItemSprite(item: item)
            .modifier(PopIn(index: index,
                            enabled: !reduceMotion
                                && index < AppTheme.popInItemLimit
                                && !animatedItemIDs.contains(item.id),
                            onFinished: { animatedItemIDs.insert(item.id) }))
            .opacity(slotOpacity(for: item))
            .onTapGesture { selectedItem = item }
            .gesture(consumeGesture(for: item))
    }

    private func slotOpacity(for item: FridgeItem) -> Double {
        guard draggedItem != nil else { return 1 }
        return item === draggedItem ? 0.25 : 0.4
    }

    // MARK: Drag to consume

    private func consumeGesture(for item: FridgeItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("fridge")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if draggedItem == nil {
                    draggedItem = item
                    dragScale = 1.3
                }
                dragLocation = drag.location
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    endDrag(at: drag.location)
                } else {
                    clearDrag()
                }
            }
    }

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
            }
            Button {
                scanFlow.startScan(from: .photoLibrary)
            } label: {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
            Button {
                showManualAdd = true
            } label: {
                Label("Type to add", systemImage: "square.and.pencil")
            }
            #if DEBUG
            Button {
                scanFlow.scanSampleReceipt()
            } label: {
                Label("Try sample receipt", systemImage: "testtube.2")
            }
            Button {
                PreviewData.seed(into: context)
            } label: {
                Label("Seed the App", systemImage: "sparkles")
            }
            #endif
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
        .accessibilityLabel("Add items")
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
