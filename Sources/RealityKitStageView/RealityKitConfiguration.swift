import Foundation
import RealityKit

/// Configuration for the RealityKit viewport.
public struct RealityKitConfiguration: Sendable {
    public var showGrid: Bool = true
    public var showAxes: Bool = true
    public var metersPerUnit: Double = 1.0
    public var isZUp: Bool = false
    public var environmentMapURL: URL?
    public var environmentExposure: Float = 0.0
    public var environmentRotation: Float = 0.0
    public var showEnvironmentBackground: Bool = true

    public init(
        showGrid: Bool = true,
        showAxes: Bool = true,
        metersPerUnit: Double = 1.0,
        isZUp: Bool = false,
        environmentMapURL: URL? = nil,
        environmentExposure: Float = 0.0,
        environmentRotation: Float = 0.0,
        showEnvironmentBackground: Bool = true
    ) {
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.environmentMapURL = environmentMapURL
        self.environmentExposure = environmentExposure
        self.environmentRotation = environmentRotation
        self.showEnvironmentBackground = showEnvironmentBackground
    }

    public var realityKitIntensityExponent: Float {
        return environmentExposure
    }
}
