import SwiftUI
import simd
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

public struct ArcballCameraState: Equatable, Sendable {
    public var focus: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var distance: Float

    public init(focus: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero, distance: Float = 5.0) {
        self.focus = focus
        self.rotation = rotation
        self.distance = distance
    }

    public var transform: simd_float4x4 {
        let rotX = simd_quatf(angle: rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: rotation.y, axis: [0, 1, 0])
        let rotationMatrix = simd_float4x4(rotY * rotX)

        let translateFocus = simd_float4x4(
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [focus.x, focus.y, focus.z, 1]
        )

        let translateDist = simd_float4x4(
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, distance, 1]
        )

        return translateFocus * rotationMatrix * translateDist
    }

    public var quaternion: simd_quatf {
        let rotX = simd_quatf(angle: rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: rotation.y, axis: [0, 1, 0])
        return rotY * rotX
    }
}

#if os(macOS)
public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    let metersPerUnit: Double
    let maxDistanceOverride: Float?

    @State private var startDistance: Float?
    @State private var previousOrbitValue: DragGesture.Value?
    @State private var previousPanValue: DragGesture.Value?
    @State private var lastClampedEdge: ClampEdge?
    @State private var eventRegionView: NSView?
    @State private var scrollMonitor: LocalScrollEventMonitor?

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        metersPerUnit: Double = 1.0,
        maxDistance: Float? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.maxDistanceOverride = maxDistance
    }

    public func body(content: Content) -> some View {
        let orbitDrag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                handleOrbitDrag(value)
                previousOrbitValue = value
            }
            .onEnded { _ in
                startDistance = nil
                previousOrbitValue = nil
            }

        let panDrag = DragGesture(minimumDistance: 1)
            .modifiers(.option)
            .onChanged { value in
                handlePanDrag(value)
                previousPanValue = value
            }
            .onEnded { _ in
                startDistance = nil
                previousPanValue = nil
            }

        let magnifyGesture = MagnificationGesture()
            .onChanged { value in
                handleMagnification(value)
            }
            .onEnded { _ in
                startDistance = nil
            }

        content
            .gesture(orbitDrag)
            .gesture(panDrag)
            .simultaneousGesture(magnifyGesture)
            // Geometry anchor used to filter scroll events to just this viewport.
            .background(EventRegionView { view in
                self.eventRegionView = view
            })
            .onAppear {
                guard scrollMonitor == nil else { return }
                scrollMonitor = LocalScrollEventMonitor { event in
                    guard shouldHandleScrollEvent(event) else {
                        return event
                    }

                    // Consume scroll events in the viewport so parent scroll views
                    // (and other SwiftUI controls) don't react at the same time.
                    if event.modifierFlags.contains(.option) {
                        let delta = Float(event.scrollingDeltaY)
                        let newDistance = state.distance * exp(delta * 0.01)
                        state.distance = clampDistance(newDistance)
                    } else {
                        let multiplier: Float = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
                        let deltaX = Float(event.scrollingDeltaX) * multiplier
                        let deltaY = Float(event.scrollingDeltaY) * multiplier
                        handlePan(deltaX: deltaX, deltaY: deltaY)
                    }
                    return nil
                }
            }
            .onDisappear {
                // Tear down the monitor when the viewport goes away.
                scrollMonitor = nil
            }
    }

    private enum ClampEdge {
        case min
        case max
    }

    private let clampEpsilon: Float = 0.0001
    private var minDistance: Float {
        ViewportTuning.minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    private var maxDistanceValue: Float {
        if let override = maxDistanceOverride {
            return Swift.max(override, minDistance)
        }
        return ViewportTuning.maximumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    private func clampDistance(_ value: Float) -> Float {
        let maxDistance = maxDistanceValue
        let clamped = Swift.min(Swift.max(value, minDistance), maxDistance)
        let edge: ClampEdge?

        if clamped <= minDistance + clampEpsilon {
            edge = .min
        } else if clamped >= maxDistance - clampEpsilon {
            edge = .max
        } else {
            edge = nil
        }

        if edge != lastClampedEdge {
            if edge != nil {
                performHapticFeedback()
            }
            lastClampedEdge = edge
        }

        return clamped
    }

    private func performHapticFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func handleOrbitDrag(_ value: DragGesture.Value) {
        let sensitivity: Float = 0.01
        let deltaX = Float(value.translation.width - (previousOrbitValue?.translation.width ?? 0))
        let deltaY = Float(value.translation.height - (previousOrbitValue?.translation.height ?? 0))
        var newRotation = state.rotation
        newRotation.y -= deltaX * sensitivity
        newRotation.x -= deltaY * sensitivity
        newRotation.x = Swift.max(-.pi / 2 + 0.01, Swift.min(.pi / 2 - 0.01, newRotation.x))
        state.rotation = newRotation
    }

    private func handlePanDrag(_ value: DragGesture.Value) {
        let deltaX = Float(value.translation.width - (previousPanValue?.translation.width ?? 0))
        let deltaY = Float(value.translation.height - (previousPanValue?.translation.height ?? 0))
        let scale = ViewportTuning.panScale(
            distance: state.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        handlePan(deltaX: deltaX, deltaY: -deltaY, scale: scale)
    }

    private func handlePan(deltaX: Float, deltaY: Float, scale: Float? = nil) {
        let panScale = scale ?? ViewportTuning.panScale(
            distance: state.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        let rotX = simd_quatf(angle: state.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: state.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX

        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])

        state.focus += (right * (-deltaX * panScale)) + (up * (deltaY * panScale))
    }

    private func handleMagnification(_ magnification: CGFloat) {
        if startDistance == nil { startDistance = state.distance }
        guard let start = startDistance else { return }
        guard magnification > 0 else { return }
        let newDistance = start / Float(magnification)
        state.distance = clampDistance(newDistance)
    }

    @MainActor
    private func shouldHandleScrollEvent(_ event: NSEvent) -> Bool {
        guard let view = eventRegionView else { return false }
        guard let window = view.window, window == event.window else { return false }

        let viewRectInWindow = view.convert(view.bounds, to: nil)
        let viewRectOnScreen = window.convertToScreen(viewRectInWindow)
        let mouseOnScreen = NSEvent.mouseLocation
        return viewRectOnScreen.contains(mouseOnScreen)
    }
}
#else
public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    let metersPerUnit: Double
    let maxDistanceOverride: Float?

    @State private var startDistance: Float?
    @State private var previousDragValue: DragGesture.Value?
    @State private var previousPanValue: DragGesture.Value?
    @State private var lastClampedEdge: ClampEdge?

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        metersPerUnit: Double = 1.0,
        maxDistance: Float? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.maxDistanceOverride = maxDistance
    }

    public func body(content: Content) -> some View {
        let orbitGesture = DragGesture(minimumDistance: 0)
            .onChanged { value in
                let deltaX = Float(value.translation.width - (previousDragValue?.translation.width ?? 0))
                let deltaY = Float(value.translation.height - (previousDragValue?.translation.height ?? 0))
                handleOrbit(deltaX: deltaX, deltaY: deltaY)
                previousDragValue = value
            }
            .onEnded { _ in
                startDistance = nil
                previousDragValue = nil
            }

        let panGesture = LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(true, drag?) = value else { return }
                let deltaX = Float(drag.translation.width - (previousPanValue?.translation.width ?? 0))
                let deltaY = Float(drag.translation.height - (previousPanValue?.translation.height ?? 0))
                handlePan(deltaX: deltaX, deltaY: deltaY)
                previousPanValue = drag
            }
            .onEnded { _ in
                previousPanValue = nil
            }

        let magnificationGesture = MagnificationGesture()
            .onChanged { value in
                handleZoom(magnification: value)
            }
            .onEnded { _ in
                startDistance = nil
            }

        return content
            .gesture(orbitGesture)
            .highPriorityGesture(panGesture)
            .simultaneousGesture(magnificationGesture)
    }

    private enum ClampEdge {
        case min
        case max
    }

    private let clampEpsilon: Float = 0.0001
    private var minDistance: Float {
        ViewportTuning.minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    private var maxDistanceValue: Float {
        if let override = maxDistanceOverride {
            return Swift.max(override, minDistance)
        }
        return ViewportTuning.maximumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    private func clampDistance(_ value: Float) -> Float {
        let maxDistance = maxDistanceValue
        let clamped = Swift.min(Swift.max(value, minDistance), maxDistance)
        let edge: ClampEdge?

        if clamped <= minDistance + clampEpsilon {
            edge = .min
        } else if clamped >= maxDistance - clampEpsilon {
            edge = .max
        } else {
            edge = nil
        }

        if edge != lastClampedEdge {
            if edge != nil {
                performHapticFeedback()
            }
            lastClampedEdge = edge
        }

        return clamped
    }

    private func performHapticFeedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func handleOrbit(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.01
        var newRotation = state.rotation
        newRotation.y -= deltaX * sensitivity
        newRotation.x -= deltaY * sensitivity
        newRotation.x = Swift.max(-.pi / 2 + 0.01, Swift.min(.pi / 2 - 0.01, newRotation.x))
        state.rotation = newRotation
    }

    private func handlePan(deltaX: Float, deltaY: Float) {
        let scale = ViewportTuning.panScale(
            distance: state.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        let rotX = simd_quatf(angle: state.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: state.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX

        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])

        state.focus += (right * (-deltaX * scale)) + (up * (deltaY * scale))
    }

    private func handleZoom(magnification: CGFloat) {
        if startDistance == nil { startDistance = state.distance }
        guard let start = startDistance else { return }
        guard magnification > 0 else { return }
        let newDistance = start / Float(magnification)
        state.distance = clampDistance(newDistance)
    }
}
#endif
