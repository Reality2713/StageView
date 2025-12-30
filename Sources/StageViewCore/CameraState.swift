import Foundation

/// Camera position and rotation state for viewport control.
public struct CameraState: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var rotation: SIMD3<Float>  // Euler angles in radians

    public init(position: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero) {
        self.position = position
        self.rotation = rotation
    }

    public static let zero = CameraState()
}
