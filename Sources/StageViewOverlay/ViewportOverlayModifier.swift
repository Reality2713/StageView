import SwiftUI

/// A view modifier that adds a coordinated viewport overlay surface.
///
/// This modifier provides a unified way to add overlays to any viewport view,
/// coordinating built-ins (gizmo, scale) and external accessories through
/// anchored positioning.
///
/// Example:
/// ```swift
/// RealityKitStageView(...)
///     .viewportOverlay(
///         items: ViewportOverlayCollection()
///             .orientationGizmo(anchor: .bottomLeading)
///             .scaleIndicator(anchor: .top),
///         snapshot: overlaySnapshot
///     ) { item in
///         // Host-provided accessories
///         if item.role == .hostAccessory {
///             RendererBadge()
///         }
///     }
/// ```
public struct ViewportOverlayModifier<AccessoryContent: View>: ViewModifier {
    let items: ViewportOverlayCollection
    let builtInVisibility: StageViewBuiltInOverlayVisibility
    let snapshot: StageViewOverlaySnapshot
    @ViewBuilder let accessoryContent: (ViewportOverlayItem) -> AccessoryContent
    @State private var viewportWidth: CGFloat = 0

    public init(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
        snapshot: StageViewOverlaySnapshot,
        @ViewBuilder accessoryContent: @escaping (ViewportOverlayItem) -> AccessoryContent
    ) {
        self.items = items
        self.builtInVisibility = builtInVisibility
        self.snapshot = snapshot
        self.accessoryContent = accessoryContent
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ViewportOverlayContainer(
                    items: items,
                    builtInVisibility: builtInVisibility,
                    snapshot: snapshot,
                    viewportWidth: viewportWidth,
                    accessoryContent: accessoryContent
                )
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                viewportWidth = newWidth
            }
    }
}

extension ViewportOverlayModifier where AccessoryContent == EmptyView {
    /// Creates a modifier with only built-in overlays.
    public init(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
        snapshot: StageViewOverlaySnapshot
    ) {
        self.init(
            items: items,
            builtInVisibility: builtInVisibility,
            snapshot: snapshot,
            accessoryContent: { _ in EmptyView() }
        )
    }
}

public extension View {
    /// Adds a coordinated viewport overlay surface with anchored positioning.
    ///
    /// - Parameters:
    ///   - items: The collection of overlay items defining what appears and where.
    ///   - builtInVisibility: Visibility settings for built-in overlays (gizmo, scale).
    ///   - snapshot: Data snapshot for built-in overlay rendering.
    ///   - accessoryContent: Builder for external accessories (host/domain-provided).
    func viewportOverlay<Content: View>(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
        snapshot: StageViewOverlaySnapshot,
        @ViewBuilder accessoryContent: @escaping (ViewportOverlayItem) -> Content
    ) -> some View {
        modifier(ViewportOverlayModifier(
            items: items,
            builtInVisibility: builtInVisibility,
            snapshot: snapshot,
            accessoryContent: accessoryContent
        ))
    }

    /// Adds a coordinated viewport overlay surface with only built-in overlays.
    func viewportOverlay(
        items: ViewportOverlayCollection,
        builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
        snapshot: StageViewOverlaySnapshot
    ) -> some View {
        modifier(ViewportOverlayModifier(
            items: items,
            builtInVisibility: builtInVisibility,
            snapshot: snapshot
        ))
    }

    /// Applies the standard viewport badge material (glass on macOS 26+/iOS 26+, ultraThinMaterial fallback).
    func viewportBadgeMaterial() -> some View {
        modifier(ViewportBadgeMaterialModifier())
    }
}

/// Standard material modifier for viewport badge overlays.
private struct ViewportBadgeMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: Capsule())
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
        #endif
    }
}
