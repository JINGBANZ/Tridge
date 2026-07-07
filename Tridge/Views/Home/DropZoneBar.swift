import SwiftUI

enum DropZone: CaseIterable {
    case ate, tossed

    var icon: String {
        switch self {
        case .ate: "😋"
        case .tossed: "🗑️"
        }
    }

    var label: String {
        switch self {
        case .ate: "Ate it"
        case .tossed: "Tossed"
        }
    }
}

/// Reports each zone's frame (in the named "fridge" space) for drag hit-testing.
struct DropZoneFramesKey: PreferenceKey {
    static var defaultValue: [DropZone: CGRect] { [:] }
    static func reduce(value: inout [DropZone: CGRect], nextValue: () -> [DropZone: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The two consume targets that slide up over the scan button during a drag.
struct DropZoneBar: View {
    /// The zone currently hovered by the dragged item, if any.
    let hotZone: DropZone?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DropZone.allCases, id: \.self) { zone in
                zoneView(zone, isHot: zone == hotZone)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func zoneView(_ zone: DropZone, isHot: Bool) -> some View {
        VStack(spacing: 2) {
            Text(zone.icon).font(.system(size: 24))
            Text(zone.label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isHot ? AppTheme.brandGreen : AppTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.dropZoneHeight)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.dropZoneRadius)
                .fill(isHot ? AnyShapeStyle(AppTheme.fresh.opacity(0.18))
                            : AnyShapeStyle(.ultraThinMaterial))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.dropZoneRadius)
                .strokeBorder(isHot ? AppTheme.fresh : AppTheme.mutedInk.opacity(0.5),
                              style: StrokeStyle(lineWidth: 2, dash: isHot ? [] : [6, 5]))
        }
        .scaleEffect(isHot ? 1.04 : 1)
        .shadow(color: isHot ? AppTheme.brandGreen.opacity(0.25) : .clear, radius: 9, y: 6)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DropZoneFramesKey.self,
                                       value: [zone: proxy.frame(in: .named("fridge"))])
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHot)
    }
}
