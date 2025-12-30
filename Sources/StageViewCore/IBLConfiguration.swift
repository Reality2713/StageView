import Foundation

public struct IBLConfiguration: Equatable, Sendable {
    public var environmentURL: URL?
    public var exposure: Float = 0.0           // EV-style: 0 = neutral, +1 = 2x, -1 = 0.5x
    public var showBackground: Bool = true
    public var rotation: Float = 0.0           // Degrees

    public init() {}

    /// Convert EV exposure to RealityKit's intensityExponent (base-10)
    public var realityKitIntensityExponent: Float {
        // EV uses base-2, intensityExponent uses base-10
        // intensityExponent = log10(2^exposure)
        return exposure * 0.30103  // log10(2) ≈ 0.30103
    }
}
