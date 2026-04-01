import OSLog
import SwiftUI

private let logger = Logger(subsystem: "StageViewOverlay", category: "ViewportOverlay")

/// A neutral viewport overlay container that coordinates built-ins and external accessories.
///
/// This container manages overlay positioning using anchored regions rather than free-form
/// coordinates. All overlay items—built-ins (gizmo, scale) and external accessories—
/// participate in the same coordinated layout surface to prevent overlap.
public struct ViewportOverlayContainer<AccessoryContent: View>: View {
    /// The anchored overlay items defining what appears and where.
    public let items: ViewportOverlayCollection

    /// Visibility state for built-in overlays.
    public let builtInVisibility: StageViewBuiltInOverlayVisibility

    /// Snapshot data for built-in overlay rendering (camera rotation, depth, etc.).
    public let snapshot: StageViewOverlaySnapshot

    /// The viewport width for scale indicator calculations.
    public let viewportWidth: CGFloat

    /// External accessory content builder, indexed by item ID.
    @ViewBuilder public let accessoryContent: (ViewportOverlayItem) -> AccessoryContent

    public init(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility,
        snapshot: StageViewOverlaySnapshot,
        viewportWidth: CGFloat,
        @ViewBuilder accessoryContent: @escaping (ViewportOverlayItem) -> AccessoryContent
    ) {
        self.items = items
        self.builtInVisibility = builtInVisibility
        self.snapshot = snapshot
        self.viewportWidth = viewportWidth
        self.accessoryContent = accessoryContent
    }

    public var body: some View {
        let grouped = items.groupedAndSortedForDisplay()

        ZStack {
            // Render each anchor region
            ForEach(ViewportOverlayAnchor.allCases, id: \.self) { anchor in
                if let anchorItems = grouped[anchor], !anchorItems.isEmpty {
                    AnchorRegion(
                        anchor: anchor,
                        items: anchorItems,
                        builtInVisibility: builtInVisibility,
                        snapshot: snapshot,
                        viewportWidth: viewportWidth,
                        accessoryContent: accessoryContent
                    )
                }
            }
        }
        .padding(12)
        .task {
            logger.debug("Rendering \(self.items.items.count) overlay items")
            for item in self.items.items {
                logger.debug("  - \(String(describing: item.role)) at \(String(describing: item.anchor)), content=\(item.content != nil)")
            }
        }
    }
}

/// A region at a specific anchor containing stacked overlay items.
private struct AnchorRegion<AccessoryContent: View>: View {
    let anchor: ViewportOverlayAnchor
    let items: [ViewportOverlayItem]
    let builtInVisibility: StageViewBuiltInOverlayVisibility
    let snapshot: StageViewOverlaySnapshot
    let viewportWidth: CGFloat
    @ViewBuilder let accessoryContent: (ViewportOverlayItem) -> AccessoryContent

    var body: some View {
        let content = Group {
            ForEach(items) { item in
                AnchorItemContent(
                    item: item,
                    builtInVisibility: builtInVisibility,
                    snapshot: snapshot,
                    viewportWidth: viewportWidth,
                    accessoryContent: accessoryContent
                )
            }
        }

        Group {
            switch anchor.stackAxis {
            case .horizontal:
                HStack(spacing: 8) {
                    content
                }
            case .vertical:
                VStack(spacing: 8) {
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor.alignment)
    }
}

/// The content for a single anchor item, rendering built-ins or external accessories.
private struct AnchorItemContent<AccessoryContent: View>: View {
    let item: ViewportOverlayItem
    let builtInVisibility: StageViewBuiltInOverlayVisibility
    let snapshot: StageViewOverlaySnapshot
    let viewportWidth: CGFloat
    @ViewBuilder let accessoryContent: (ViewportOverlayItem) -> AccessoryContent

    var body: some View {
        switch item.role {
        case .orientationGizmo:
            if builtInVisibility.showsOrientationGizmo,
               let cameraRotation = snapshot.cameraRotation,
               cameraRotation.vector.isFinite {
                OrientationGizmoView(
                    cameraRotation: cameraRotation,
                    isZUp: snapshot.isZUp
                )
                .allowsHitTesting(false)
            }

        case .scaleIndicator:
            if builtInVisibility.showsScaleIndicator,
               let referenceDepthMeters = snapshot.referenceDepthMeters,
               referenceDepthMeters.isFinite,
               referenceDepthMeters > 0 {
                ScaleIndicatorView(
                    referenceDepthMeters: referenceDepthMeters,
                    viewportWidthPoints: Double(max(1, viewportWidth)),
                    horizontalFOVDegrees: snapshot.horizontalFOVDegrees
                )
                .allowsHitTesting(false)
            }

        case .hostAccessory, .domainAccessory:
            if let content = item.content {
                content.view
            } else {
                accessoryContent(item)
            }
        }
    }
}

// MARK: - Convenience Initializers

extension ViewportOverlayContainer where AccessoryContent == EmptyView {
    /// Creates a container with only built-in overlays (no external accessories).
    public init(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility,
        snapshot: StageViewOverlaySnapshot,
        viewportWidth: CGFloat
    ) {
        self.init(
            items: items,
            builtInVisibility: builtInVisibility,
            snapshot: snapshot,
            viewportWidth: viewportWidth,
            accessoryContent: { _ in EmptyView() }
        )
    }
}

// MARK: - Legacy Compatibility

extension ViewportOverlayContainer {
    /// Creates a container from legacy slot-based configuration.
    ///
    /// This initializer provides backward compatibility while migrating to the anchored model.
    @available(*, deprecated, message: "Use ViewportOverlayCollection-based initializer")
    public init(
        legacySlots: StageViewOverlaySlots,
        snapshot: StageViewOverlaySnapshot,
        viewportWidth: CGFloat,
        @ViewBuilder accessoryContent: @escaping (ViewportOverlayItem) -> AccessoryContent
    ) {
        var items = ViewportOverlayCollection()

        // Map legacy slots to anchored items
        if legacySlots.topLeading != nil {
            items = items.hostAccessory(anchor: .topLeading)
        }
        if legacySlots.top != nil {
            items = items.hostAccessory(anchor: .top)
        }
        if legacySlots.topTrailing != nil {
            items = items.hostAccessory(anchor: .topTrailing)
        }
        if legacySlots.bottomLeading != nil {
            items = items.hostAccessory(anchor: .bottomLeading)
        }
        if legacySlots.bottom != nil {
            items = items.hostAccessory(anchor: .bottom)
        }
        if legacySlots.bottomTrailing != nil {
            items = items.hostAccessory(anchor: .bottomTrailing)
        }

        self.init(
            items: items,
            builtInVisibility: snapshot.builtInVisibility,
            snapshot: snapshot,
            viewportWidth: viewportWidth,
            accessoryContent: accessoryContent
        )
    }
}
