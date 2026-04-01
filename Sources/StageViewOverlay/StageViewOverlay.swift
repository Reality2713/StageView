import Foundation
import SwiftUI
import simd

// MARK: - Anchored Overlay API (New)

/// The primary entry point for viewport overlay configuration.
///
/// Use `ViewportOverlayCollection` to declaratively specify which overlays appear
/// and where they are anchored. Built-ins and external accessories participate
/// in the same coordinated layout surface.
///
/// Example:
/// ```swift
/// let overlays = ViewportOverlayCollection()
///     .orientationGizmo(anchor: .bottomLeading)
///     .scaleIndicator(anchor: .top)
///     .hostAccessory(anchor: .topLeading)
/// ```
public typealias ViewportOverlayConfiguration = ViewportOverlayCollection

// MARK: - Legacy Slot API (Deprecated)

extension StageViewOverlaySlots {
    /// Converts legacy slots to the new anchored collection, preserving view content.
    @available(*, deprecated, message: "Migrate to ViewportOverlayCollection")
    public func toAnchoredCollection() -> ViewportOverlayCollection {
        var collection = ViewportOverlayCollection()

        if let topLeading {
            collection = collection.hostAccessory(anchor: .topLeading, content: UncheckedAnyViewBox(topLeading))
        }
        if let top {
            collection = collection.hostAccessory(anchor: .top, content: UncheckedAnyViewBox(top))
        }
        if let topTrailing {
            collection = collection.hostAccessory(anchor: .topTrailing, content: UncheckedAnyViewBox(topTrailing))
        }
        if let bottomLeading {
            collection = collection.hostAccessory(anchor: .bottomLeading, content: UncheckedAnyViewBox(bottomLeading))
        }
        if let bottom {
            collection = collection.hostAccessory(anchor: .bottom, content: UncheckedAnyViewBox(bottom))
        }
        if let bottomTrailing {
            collection = collection.hostAccessory(anchor: .bottomTrailing, content: UncheckedAnyViewBox(bottomTrailing))
        }

        return collection
    }
}

// MARK: - Built-in Components

public struct DynamicScaleReference: Equatable {
    public let meters: Double
    public let label: String

    public init(meters: Double, label: String) {
        self.meters = meters
        self.label = label
    }

    public static func compute(
        referenceDepthMeters: Double,
        horizontalFOVDegrees: Double,
        viewportWidthPoints: Double,
        barWidthPoints: Double
    ) -> DynamicScaleReference? {
        guard referenceDepthMeters.isFinite, referenceDepthMeters > 0 else { return nil }
        guard horizontalFOVDegrees.isFinite, horizontalFOVDegrees > 1, horizontalFOVDegrees < 179 else { return nil }
        guard viewportWidthPoints.isFinite, viewportWidthPoints > 1 else { return nil }
        guard barWidthPoints.isFinite, barWidthPoints > 1 else { return nil }

        let fovRadians = horizontalFOVDegrees * .pi / 180.0
        let visibleWidthMeters = 2.0 * referenceDepthMeters * tan(fovRadians / 2.0)
        guard visibleWidthMeters.isFinite, visibleWidthMeters > 0 else { return nil }

        let rawMeters = visibleWidthMeters * (barWidthPoints / viewportWidthPoints)
        guard rawMeters.isFinite, rawMeters > 0 else { return nil }

        let snappedMeters = snapToNiceMetricStep(rawMeters)
        return .init(meters: snappedMeters, label: formatMetric(snappedMeters))
    }

    private static func snapToNiceMetricStep(_ value: Double) -> Double {
        let clamped = min(1_000_000.0, max(0.000_001, value))
        let exponent = floor(log10(clamped))
        let magnitude = pow(10.0, exponent)
        let normalized = clamped / magnitude
        let candidates: [Double] = [1, 2, 5, 10]
        let nearest = candidates.min { lhs, rhs in
            Swift.abs(lhs - normalized) < Swift.abs(rhs - normalized)
        } ?? 1.0
        return nearest * magnitude
    }

    private static func formatMetric(_ meters: Double) -> String {
        let value: Double
        let unit: String
        if meters < 0.01 {
            value = meters * 1000
            unit = "mm"
        } else if meters < 1.0 {
            value = meters * 100
            unit = "cm"
        } else if meters < 1000 {
            value = meters
            unit = "m"
        } else {
            value = meters / 1000
            unit = "km"
        }
        return "\(compact(value))\(unit)"
    }

    private static func compact(_ value: Double) -> String {
        if value >= 100 || Swift.abs(value.rounded() - value) < 0.001 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

public struct StageViewBuiltInOverlayVisibility {
    public var showsOrientationGizmo: Bool
    public var showsScaleIndicator: Bool

    public init(
        showsOrientationGizmo: Bool = true,
        showsScaleIndicator: Bool = true
    ) {
        self.showsOrientationGizmo = showsOrientationGizmo
        self.showsScaleIndicator = showsScaleIndicator
    }
}

public struct StageViewOverlaySnapshot {
    public var builtInVisibility: StageViewBuiltInOverlayVisibility
    public var cameraRotation: simd_quatf?
    public var horizontalFOVDegrees: Double
    public var isZUp: Bool
    public var referenceDepthMeters: Double?

    public init(
        builtInVisibility: StageViewBuiltInOverlayVisibility = .init(),
        cameraRotation: simd_quatf? = nil,
        horizontalFOVDegrees: Double = 60,
        isZUp: Bool = false,
        referenceDepthMeters: Double? = nil
    ) {
        self.builtInVisibility = builtInVisibility
        self.cameraRotation = cameraRotation
        self.horizontalFOVDegrees = horizontalFOVDegrees
        self.isZUp = isZUp
        self.referenceDepthMeters = referenceDepthMeters
    }

    public var showsBuiltInContent: Bool {
        builtInVisibility.showsOrientationGizmo || builtInVisibility.showsScaleIndicator
    }
}

/// Deprecated slot-based overlay configuration.
///
/// Use `ViewportOverlayCollection` instead for anchored overlay positioning.
@available(*, deprecated, message: "Use ViewportOverlayCollection with anchored positioning")
public struct StageViewOverlaySlots {
    public var bottom: AnyView?
    public var bottomLeading: AnyView?
    public var bottomTrailing: AnyView?
    public var top: AnyView?
    public var topLeading: AnyView?
    public var topTrailing: AnyView?

    public init(
        bottom: AnyView? = nil,
        bottomLeading: AnyView? = nil,
        bottomTrailing: AnyView? = nil,
        top: AnyView? = nil,
        topLeading: AnyView? = nil,
        topTrailing: AnyView? = nil
    ) {
        self.bottom = bottom
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.top = top
        self.topLeading = topLeading
        self.topTrailing = topTrailing
    }

    public static var empty: Self { Self() }

    public var hasContent: Bool {
        bottom != nil
            || bottomLeading != nil
            || bottomTrailing != nil
            || top != nil
            || topLeading != nil
            || topTrailing != nil
    }

    public func bottom<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.bottom = AnyView(content())
        return copy
    }

    public func bottomLeading<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.bottomLeading = AnyView(content())
        return copy
    }

    public func bottomTrailing<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.bottomTrailing = AnyView(content())
        return copy
    }

    public func top<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.top = AnyView(content())
        return copy
    }

    public func topLeading<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.topLeading = AnyView(content())
        return copy
    }

    public func topTrailing<Content: View>(@ViewBuilder _ content: () -> Content) -> Self {
        var copy = self
        copy.topTrailing = AnyView(content())
        return copy
    }
}

/// Deprecated slot-based overlay container.
///
/// Use `ViewportOverlayContainer` with `ViewportOverlayCollection` instead.
@available(*, deprecated, message: "Use ViewportOverlayContainer with anchored positioning")
public struct StageViewOverlayContainer: View {
    public let slots: StageViewOverlaySlots
    public let snapshot: StageViewOverlaySnapshot

    public init(
        slots: StageViewOverlaySlots = .empty,
        snapshot: StageViewOverlaySnapshot
    ) {
        self.slots = slots
        self.snapshot = snapshot
    }

    public var body: some View {
        if showsOverlay {
            StageViewOverlayRoot(
                slots: slots,
                snapshot: snapshot
            )
        }
    }
    
    private var showsOverlay: Bool {
        slots.hasContent || snapshot.showsBuiltInContent
    }
}

/// Deprecated.
@available(*, deprecated)
private struct StageViewOverlayRoot: View {
    let slots: StageViewOverlaySlots
    let snapshot: StageViewOverlaySnapshot
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        StageViewOverlayEffectContainer {
            StageViewOverlayChrome(
                slots: slots,
                snapshot: snapshot,
                viewportWidth: viewportWidth
            )
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            viewportWidth = newWidth
        }
    }
}

/// Deprecated.
@available(*, deprecated)
private struct StageViewOverlayChrome: View {
    let slots: StageViewOverlaySlots
    let snapshot: StageViewOverlaySnapshot
    let viewportWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            StageViewOverlayTopRow(
                slots: slots,
                snapshot: snapshot,
                viewportWidth: viewportWidth
            )

            Spacer(minLength: 0)

            StageViewOverlayBottomRow(
                slots: slots,
                snapshot: snapshot
            )
        }
        .safeAreaPadding()
        .padding()
    }
}

/// Deprecated.
@available(*, deprecated)
private struct StageViewOverlayTopRow: View {
    let slots: StageViewOverlaySlots
    let snapshot: StageViewOverlaySnapshot
    let viewportWidth: CGFloat

    var body: some View {
        HStack(alignment: .top) {
            StageViewOverlaySlot(
                view: slots.topLeading,
                alignment: .leading
            )
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                StageViewBuiltInScaleIndicator(
                    snapshot: snapshot,
                    viewportWidth: viewportWidth
                )
                StageViewOverlaySlot(
                    view: slots.top,
                    alignment: .center
                )
            }
            Spacer(minLength: 0)
            StageViewOverlaySlot(
                view: slots.topTrailing,
                alignment: .trailing
            )
        }
    }
}

/// Deprecated.
@available(*, deprecated)
private struct StageViewOverlayBottomRow: View {
    let slots: StageViewOverlaySlots
    let snapshot: StageViewOverlaySnapshot

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                StageViewOverlaySlot(
                    view: slots.bottomLeading,
                    alignment: .leading
                )
                StageViewBuiltInOrientationGizmo(snapshot: snapshot)
            }
            Spacer(minLength: 0)
            StageViewOverlaySlot(
                view: slots.bottom,
                alignment: .center
            )
            Spacer(minLength: 0)
            StageViewOverlaySlot(
                view: slots.bottomTrailing,
                alignment: .trailing
            )
        }
    }
}

/// Deprecated.
@available(*, deprecated)
private struct StageViewOverlaySlot: View {
    let view: AnyView?
    let alignment: HorizontalAlignment

    var body: some View {
        if let view {
            VStack(alignment: alignment, spacing: 0) {
                view
            }
        }
    }
}

/// Deprecated. Built-ins now render through ViewportOverlayContainer.
@available(*, deprecated)
private struct StageViewBuiltInScaleIndicator: View {
    let snapshot: StageViewOverlaySnapshot
    let viewportWidth: CGFloat

    var body: some View {
        if let referenceDepthMeters = referenceDepthMeters {
            ScaleIndicatorView(
                referenceDepthMeters: referenceDepthMeters,
                viewportWidthPoints: Double(max(1, viewportWidth)),
                horizontalFOVDegrees: snapshot.horizontalFOVDegrees
            )
            .allowsHitTesting(false)
        }
    }

    private var referenceDepthMeters: Double? {
        guard snapshot.builtInVisibility.showsScaleIndicator,
              let referenceDepthMeters = snapshot.referenceDepthMeters,
              referenceDepthMeters.isFinite,
              referenceDepthMeters > 0
        else {
            return nil
        }
        return referenceDepthMeters
    }
}

/// Deprecated. Built-ins now render through ViewportOverlayContainer.
@available(*, deprecated)
private struct StageViewBuiltInOrientationGizmo: View {
    let snapshot: StageViewOverlaySnapshot

    var body: some View {
        if let cameraRotation = cameraRotation {
            OrientationGizmoView(
                cameraRotation: cameraRotation,
                isZUp: snapshot.isZUp
            )
            .allowsHitTesting(false)
        }
    }

    private var cameraRotation: simd_quatf? {
        guard snapshot.builtInVisibility.showsOrientationGizmo,
              let cameraRotation = snapshot.cameraRotation,
              cameraRotation.vector.isFinite
        else {
            return nil
        }
        return cameraRotation
    }
}

/// Deprecated. Use `glassEffect` modifiers directly on overlay content.
@available(*, deprecated)
private struct StageViewOverlayEffectContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                content()
            }
        } else {
            content()
        }
    }
}

public struct ScaleIndicatorView: View {
    let referenceDepthMeters: Double
    let viewportWidthPoints: Double
    let barWidth: Double
    let horizontalFOVDegrees: Double

    public init(
        referenceDepthMeters: Double,
        viewportWidthPoints: Double,
        barWidth: Double = 88,
        horizontalFOVDegrees: Double = 60
    ) {
        self.referenceDepthMeters = referenceDepthMeters
        self.viewportWidthPoints = viewportWidthPoints
        self.barWidth = barWidth
        self.horizontalFOVDegrees = horizontalFOVDegrees
    }

    public var body: some View {
        if let scale = DynamicScaleReference.compute(
            referenceDepthMeters: referenceDepthMeters,
            horizontalFOVDegrees: horizontalFOVDegrees,
            viewportWidthPoints: viewportWidthPoints,
            barWidthPoints: barWidth
        ) {
            VStack(spacing: 3) {
                Rectangle()
                    .fill(.secondary.opacity(0.8))
                    .frame(width: barWidth, height: 1.5)
                Text(scale.label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .stageViewOverlayMaterial(in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

public struct OrientationGizmoView: View {
    public let cameraRotation: simd_quatf
    public var size: CGFloat
    public var isZUp: Bool

    public init(
        cameraRotation: simd_quatf,
        size: CGFloat = 80,
        isZUp: Bool = false
    ) {
        self.cameraRotation = cameraRotation
        self.size = size
        self.isZUp = isZUp
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let axisLength = min(canvasSize.width, canvasSize.height) * 0.35
            let invRotation = cameraRotation.inverse
            let xAxis = rotatePoint(SIMD3<Float>(1, 0, 0), by: invRotation)
            let yAxis = rotatePoint(SIMD3<Float>(0, 1, 0), by: invRotation)
            let zAxis = rotatePoint(SIMD3<Float>(0, 0, 1), by: invRotation)
            let upAxisTag = isZUp ? "Z" : "Y"

            let axes: [(axis: SIMD3<Float>, color: Color, label: String)] = [
                (xAxis, .red, "X"),
                (yAxis, .green, "Y"),
                (zAxis, .blue, "Z"),
            ].sorted { $0.axis.z < $1.axis.z }

            for (axis, color, label) in axes {
                let isUp = label == upAxisTag
                let endPoint = CGPoint(
                    x: center.x + CGFloat(axis.x) * axisLength,
                    y: center.y - CGFloat(axis.y) * axisLength
                )

                var path = Path()
                path.move(to: center)
                path.addLine(to: endPoint)

                context.stroke(
                    path,
                    with: .color(color.opacity(0.7)),
                    lineWidth: 2.0
                )

                let arrowSize: CGFloat = isUp ? 10 : 7
                let direction = CGPoint(x: endPoint.x - center.x, y: endPoint.y - center.y)
                let length = sqrt(direction.x * direction.x + direction.y * direction.y)
                if length > 0 {
                    let norm = CGPoint(x: direction.x / length, y: direction.y / length)
                    let perp = CGPoint(x: -norm.y, y: norm.x)

                    var arrowPath = Path()
                    arrowPath.move(to: endPoint)
                    arrowPath.addLine(
                        to: CGPoint(
                            x: endPoint.x - norm.x * arrowSize + perp.x * arrowSize * 0.5,
                            y: endPoint.y - norm.y * arrowSize + perp.y * arrowSize * 0.5
                        )
                    )
                    arrowPath.addLine(
                        to: CGPoint(
                            x: endPoint.x - norm.x * arrowSize - perp.x * arrowSize * 0.5,
                            y: endPoint.y - norm.y * arrowSize - perp.y * arrowSize * 0.5
                        )
                    )
                    arrowPath.closeSubpath()
                    context.fill(arrowPath, with: .color(color.opacity(0.7)))
                }

                if axis.z > -0.3 {
                    let labelPosition = CGPoint(
                        x: endPoint.x + CGFloat(axis.x) * 12,
                        y: endPoint.y - CGFloat(axis.y) * 12
                    )
                    context.draw(
                        Text(label)
                            .font(
                                .system(
                                    size: isUp ? 13 : 11,
                                    weight: isUp ? .heavy : .bold,
                                    design: .monospaced
                                )
                            )
                            .foregroundColor(color),
                        at: labelPosition,
                        anchor: .center
                    )
                }
            }

            let originSize: CGFloat = 8
            context.fill(
                Circle().path(
                    in: CGRect(
                        x: center.x - originSize / 2,
                        y: center.y - originSize / 2,
                        width: originSize,
                        height: originSize
                    )
                ),
                with: .color(.white)
            )
        }
        .frame(width: size, height: size)
        .padding(8)
        .stageViewOverlayMaterial(in: Circle())
        .foregroundStyle(.secondary)
    }

    private func rotatePoint(_ point: SIMD3<Float>, by quat: simd_quatf) -> SIMD3<Float> {
        let rotated = quat.act(point)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z)
    }
}

public struct StageViewOverlayMaterialModifier<S: Shape>: ViewModifier {
    let shape: S

    public init(shape: S) {
        self.shape = shape
    }

    public func body(content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: shape)
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
        #endif
    }
}

public extension View {
    func stageViewOverlayMaterial<S: Shape>(in shape: S) -> some View {
        modifier(StageViewOverlayMaterialModifier(shape: shape))
    }
}

extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
