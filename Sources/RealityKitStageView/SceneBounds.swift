import Foundation

/// Scene bounds information for RealityKit viewport.
public struct SceneBounds: Equatable, Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>
    public var center: SIMD3<Float>
    public var maxExtent: Float

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
        self.center = (min + max) / 2
        let extent = max - min
        self.maxExtent = Swift.max(extent.x, Swift.max(extent.y, extent.z))
    }

    public init() {
        self.min = .zero
        self.max = .zero
        self.center = .zero
        self.maxExtent = 0
    }

    public var isFinite: Bool {
        min.x.isFinite
            && min.y.isFinite
            && min.z.isFinite
            && max.x.isFinite
            && max.y.isFinite
            && max.z.isFinite
            && center.x.isFinite
            && center.y.isFinite
            && center.z.isFinite
            && maxExtent.isFinite
    }

    public var isNonEmpty: Bool {
        max != min && maxExtent > 0
    }

    public var isFrameable: Bool {
        isFinite && isNonEmpty
    }
}
