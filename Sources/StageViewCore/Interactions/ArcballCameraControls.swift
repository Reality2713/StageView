import SwiftUI
import simd
#if os(macOS)
import AppKit
#endif

public struct ArcballCameraState: Equatable, Sendable {
    public var focus: SIMD3<Float>
    public var rotation: SIMD3<Float> // Euler angles (Pitch, Yaw, Roll)
    public var distance: Float
    
    public init(focus: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero, distance: Float = 5.0) {
        self.focus = focus
        self.rotation = rotation
        self.distance = distance
    }
    
    public var transform: simd_float4x4 {
        // Compose transform: Translate(focus) * Rotate(yaw, pitch) * Translate(0, 0, distance)
        // This orbits the camera around the focus point.
        
        // Yaw (Y-axis), Pitch (X-axis)
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

    /// Camera rotation as quaternion (for gizmo)
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
    
    // Interaction State
    @State private var startDistance: Float?
    @State private var previousDragValue: DragGesture.Value?
    
    public init(state: Binding<ArcballCameraState>, sceneBounds: SceneBounds) {
        self._state = state
        self.sceneBounds = sceneBounds
    }
    
    public func body(content: Content) -> some View {
        content
            .background {
                InteractionOverlay(
                    onScroll: { event in
                        handleNativeScroll(event)
                    },
                    onMagnify: { event in
                        handleNativeMagnify(event)
                    }
                )
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if NSEvent.modifierFlags.contains(.option) {
                            // Hydra Parity: Option + Drag = Pan
                            let multiplier: Float = NSEvent.modifierFlags.contains(.shift) ? 2.0 : 0.5
                            let deltaX = Float(value.translation.width - (previousDragValue?.translation.width ?? 0))
                            let deltaY = Float(value.translation.height - (previousDragValue?.translation.height ?? 0))
                            handlePan(deltaX: deltaX * multiplier, deltaY: deltaY * multiplier)
                        } else {
                            // Orbit
                            let deltaX = Float(value.translation.width - (previousDragValue?.translation.width ?? 0))
                            let deltaY = Float(value.translation.height - (previousDragValue?.translation.height ?? 0))
                            handleOrbit(deltaX: deltaX, deltaY: deltaY)
                        }
                        previousDragValue = value
                    }
                    .onEnded { _ in
                        startDistance = nil
                        previousDragValue = nil
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        handleZoom(magnification: value)
                    }
                    .onEnded { _ in
                        startDistance = nil
                    }
            )
    }
    
    private func handleOrbit(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.01
        
        var newRotation = state.rotation
        newRotation.y -= deltaX * sensitivity // Yaw
        newRotation.x -= deltaY * sensitivity // Pitch
        
        // Clamp pitch to prevent camera flip
        newRotation.x = max(-.pi / 2 + 0.01, min(.pi / 2 - 0.01, newRotation.x))
        
        state.rotation = newRotation
    }
    
    private func handlePan(deltaX: Float, deltaY: Float) {
        // Pan sensitivity scales with distance
        let scale = state.distance * 0.001
        
        // Calculate pan direction relative to camera rotation
        let rotX = simd_quatf(angle: state.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: state.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX
        
        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])
        
        // Hydra uses: pan(byDeltaX: -deltaX * multiplier, deltaY: -deltaY * multiplier)
        state.focus += (right * (-deltaX * scale)) + (up * (deltaY * scale))
    }
    
    private func handleZoom(magnification: CGFloat) {
        if startDistance == nil { startDistance = state.distance }
        guard let start = startDistance else { return }
        
        // Pinch out (scale > 1) -> zoom in (distance < start)
        let newDistance = start / Float(magnification)
        state.distance = max(0.01, newDistance)
    }
    
    private func handleNativeScroll(_ event: NSEvent) {
        // Hydra Parity: Scroll = Pan, Option+Scroll = Zoom
        if event.modifierFlags.contains(.option) {
            // Zoom
            let sensitivity: Float = 0.005
            let delta = Float(event.scrollingDeltaY) * sensitivity
            let newDistance = state.distance * (1.0 - delta)
            state.distance = max(0.01, newDistance)
        } else {
            // Pan
            let multiplier: Float = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
            let deltaX = Float(event.scrollingDeltaX) * multiplier
            let deltaY = Float(event.scrollingDeltaY) * multiplier
            handlePan(deltaX: deltaX, deltaY: deltaY)
        }
    }
    
    private func handleNativeMagnify(_ event: NSEvent) {
        // Pinch out (positive magnification) -> zoom in (distance decreases)
        let sensitivity: Float = 1.0
        let delta = Float(event.magnification) * sensitivity
        let newDistance = state.distance * (1.0 - delta)
        state.distance = max(0.01, newDistance)
    }
}
#endif
