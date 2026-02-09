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
    let maxDistanceOverride: Float?

    @State private var startDistance: Float?
    @State private var previousOrbitValue: DragGesture.Value?
    @State private var previousPanValue: DragGesture.Value?
    @State private var lastClampedEdge: ClampEdge?

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        maxDistance: Float? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
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
            .overlay {
                ScrollWheelOverlay(
                    onScrollPan: { deltaX, deltaY in
                        handlePan(deltaX: deltaX, deltaY: deltaY)
                    },
                    onScrollZoom: { delta in
                        let newDistance = state.distance * (1.0 - delta)
                        state.distance = clampDistance(newDistance)
                    }
                )
            }
    }

    private enum ClampEdge {
        case min
        case max
    }

    private let clampEpsilon: Float = 0.0001
    private var minDistance: Float { 0.01 }

    private var maxDistanceValue: Float {
        if let override = maxDistanceOverride {
            return Swift.max(override, minDistance)
        }
        let extent = Swift.max(Float(sceneBounds.maxExtent), 0.001)
        return Swift.max(1000.0, extent * 100000.0)
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
        let scale = state.distance * 0.001
        handlePan(deltaX: deltaX, deltaY: -deltaY, scale: scale)
    }

    private func handlePan(deltaX: Float, deltaY: Float, scale: Float? = nil) {
        let panScale = scale ?? (state.distance * 0.001)
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
}
#else
public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    let maxDistanceOverride: Float?

    @State private var startDistance: Float?
    @State private var previousDragValue: DragGesture.Value?
    @State private var previousPanValue: DragGesture.Value?
    @State private var lastClampedEdge: ClampEdge?

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        maxDistance: Float? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
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
    private var minDistance: Float { 0.01 }

    private var maxDistanceValue: Float {
        if let override = maxDistanceOverride {
            return Swift.max(override, minDistance)
        }
        let extent = Swift.max(Float(sceneBounds.maxExtent), 0.001)
        return Swift.max(1000.0, extent * 100000.0)
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
        #if os(iOS) || os(visionOS)
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
        let scale = state.distance * 0.001
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
