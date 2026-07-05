import SwiftUI
import SwiftData
import PhotosUI

/// The whole app on one screen: frameless item grid on the chilled background,
/// one scan button, drag-to-consume.
struct HomeView: View {
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
    @State private var settingsKeyExplainer = false
    @State private var pickedPhoto: PhotosPickerItem?

    // Drag-to-consume state
    @State private var draggedItem: FridgeItem?
    @State private var dragLocation: CGPoint = .zero
    @State private var dragScale: CGFloat = 1.3
    @State private var zoneFrames: [DropZone: CGRect] = [:]

    var body: some View {
        ZStack {
            AppTheme.ChillBackground()

            VStack(spacing: 0) {
                header
                if items.isEmpty {
                    EmptyStateView()
                        .padding(.bottom, AppTheme.scanButtonSize + 40)
                } else {
                    grid
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
        .sheet(isPresented: $showSettings, onDismiss: { settingsKeyExplainer = false }) {
            SettingsSheet(showKeyExplainer: settingsKeyExplainer)
        }
        .sheet(isPresented: reviewBinding) {
            ReviewSheet(model: scanFlow)
        }
        .fullScreenCover(isPresented: cameraBinding) {
            DocumentCameraView { scanFlow.handleCapture($0) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: photoPickerBinding, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                scanFlow.handleCapture(data.flatMap(UIImage.init(data:)))
            }
        }
        .alert("Scan failed", isPresented: failedBinding, actions: {
            Button("Try Again") { scanFlow.retry() }
            Button("Cancel", role: .cancel) { scanFlow.reset() }
        }, message: {
            Text("\(failureMessage)\n\nDetails were logged — Settings → Copy diagnostics.")
        })
        .onChange(of: scanFlow.phase) { _, phase in
            if phase == .needsKey {
                settingsKeyExplainer = true
                showSettings = true
                scanFlow.reset()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updateBadge() }
        }
        .onChange(of: items.count) { updateBadge() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Fridge")
                .font(AppTheme.titleFont)
                .foregroundStyle(AppTheme.ink)
            Spacer()
            HStack(spacing: 10) {
                Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(AppTheme.countFont)
                    .foregroundStyle(AppTheme.mutedInk)
                Button {
                    settingsKeyExplainer = false
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: AppTheme.gridColumnGap),
                               count: AppTheme.gridColumns),
                spacing: AppTheme.gridRowGap
            ) {
                ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { index, item in
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
            .modifier(PopIn(index: index, reduceMotion: reduceMotion))
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

    /// Tap scans (camera, or photo library where no camera exists); long-press
    /// offers the source menu. Still the home screen's single control.
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
                Label("Choose photo", systemImage: "photo.on.rectangle")
            }
            #if DEBUG
            Button {
                scanFlow.scanSampleReceipt()
            } label: {
                Label("Try sample receipt", systemImage: "testtube.2")
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
                .shadow(color: AppTheme.brandGreen.opacity(0.45), radius: 10, y: 8)
        } primaryAction: {
            scanFlow.startScan()
        }
        .accessibilityLabel("Scan receipt")
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
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : AppTheme.popInStartScale)
            .opacity(shown ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.65)
                        .delay(Double(index) * AppTheme.popInDelayPerItem)) {
                        shown = true
                    }
                }
            }
    }
}

#Preview {
    HomeView()
        .modelContainer(PreviewData.container)
}
