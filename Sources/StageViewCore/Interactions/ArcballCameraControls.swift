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
}

public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    
    // Interaction State
    @State private var startRotation: SIMD3<Float>?
    @State private var startFocus: SIMD3<Float>?
    @State private var startDistance: Float?
    @State private var previousDragValue: DragGesture.Value?
    
    public init(state: Binding<ArcballCameraState>, sceneBounds: SceneBounds) {
        self._state = state
        self.sceneBounds = sceneBounds
    }
    
    public func body(content: Content) -> some View {
        content
            .background {
                #if os(macOS)
                InteractionOverlay(
                    onScroll: { event in
                        handleNativeScroll(event)
                    },
                    onMagnify: { event in
                        handleNativeMagnify(event)
                    }
                )
                #endif
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            // User requested: Option + Click Drag = Zoom
                            // Determine deltaY for zoom
                            let deltaY = Float(value.translation.height - (previousDragValue?.translation.height ?? 0))
                            handleZoom(delta: deltaY * 0.01)
                        } else if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                            handlePan(value)
                        } else {
                            handleOrbit(value)
                        }
                        previousDragValue = value
                        #else
                        handleOrbit(value)
                        #endif
                    }
                    .onEnded { _ in
                        startRotation = nil
                        startFocus = nil
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
    
    private func handleOrbit(_ value: DragGesture.Value) {
        if startRotation == nil { startRotation = state.rotation }
        guard let start = startRotation else { return }
        
        // Sensitivity
        let sensitivity: Float = 0.01
        
        let deltaX = Float(value.translation.width) * sensitivity
        let deltaY = Float(value.translation.height) * sensitivity
        
        // Update state
        var newRotation = start
        newRotation.y -= deltaX // Yaw
        newRotation.x -= deltaY // Pitch
        
        state.rotation = newRotation
    }
    
    private func handlePan(_ value: DragGesture.Value) {
        if startFocus == nil { startFocus = state.focus }
        guard let start = startFocus else { return }
        
        // Pan sensitivity should scale with distance
        let scale = state.distance * 0.001
        
        // Calculate pan direction relative to camera rotation
        let rotX = simd_quatf(angle: state.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: state.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX
        
        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])
        
        let deltaX = Float(-value.translation.width) * scale
        let deltaY = Float(value.translation.height) * scale
        
        state.focus = start + (right * deltaX) + (up * deltaY)
    }
    
    private func handleZoom(magnification: CGFloat) {
        if startDistance == nil { startDistance = state.distance }
        guard let start = startDistance else { return }
        
        // Invert magnification: pinch out (scale > 1) -> zoom in (distance < start)
        let newDistance = start / Float(magnification)
        state.distance = max(0.01, newDistance)
    }

    private func handleZoom(delta: Float) {
        // Linear zoom based on drag delta
        // Drag down (+) = Zoom Out (increase distance), Drag Up (-) = Zoom In
        // Scaling sensitivity by distance
        let change = delta * state.distance * 2.0
        state.distance = max(0.01, state.distance + change)
    }
    
    #if os(macOS)
    private func handleNativeScroll(_ event: NSEvent) {
        // Hydra Parity:
        // Default Scroll = Pan (Translate)
        // Option + Scroll = Zoom
        
        if event.modifierFlags.contains(.option) {
             // Zoom
             let sensitivity: Float = 0.005
             let delta = Float(event.scrollingDeltaY) * sensitivity
             // distance = distance * (1 - delta)
             let newDistance = state.distance * (1.0 - delta)
             state.distance = max(0.01, newDistance)
        } else {
            // Pan
            let scale = state.distance * 0.001
            
            let rotX = simd_quatf(angle: state.rotation.x, axis: [1, 0, 0])
            let rotY = simd_quatf(angle: state.rotation.y, axis: [0, 1, 0])
            let orientation = rotY * rotX
            
            let right = orientation.act([1, 0, 0])
            let up = orientation.act([0, 1, 0])
            
            let deltaX = Float(event.scrollingDeltaX) * scale
            let deltaY = Float(-event.scrollingDeltaY) * scale
            
            state.focus += (right * deltaX) + (up * deltaY)
        }
    }
    
    private func handleNativeMagnify(_ event: NSEvent) {
        // event.magnification is the delta (e.g., 0.01 for slight pinch out)
        // Zooming: pinch out (positive magnification) -> zoom in (distance decreases)
        let sensitivity: Float = 1.0
        let delta = Float(event.magnification) * sensitivity
        
        let newDistance = state.distance * (1.0 - delta)
        state.distance = max(0.01, newDistance)
    }
    #endif
}
