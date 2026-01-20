import Foundation
import RealityKit

/// Configuration for the RealityKit viewport.
public struct RealityKitConfiguration: Sendable {
    // MARK: - Grid
    public var showGrid: Bool = true
    public var showAxes: Bool = true
    public var metersPerUnit: Double = 1.0
    
    // MARK: - Environment Lighting
    public var environmentMapURL: URL?
    public var environmentExposure: Float = 0.0
    public var environmentRotation: Float = 0.0
    public var showEnvironmentBackground: Bool = true
    
    public init(
        showGrid: Bool = true,
        showAxes: Bool = true,
        metersPerUnit: Double = 1.0,
        environmentMapURL: URL? = nil,
        environmentExposure: Float = 0.0,
        environmentRotation: Float = 0.0,
        showEnvironmentBackground: Bool = true
    ) {
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.metersPerUnit = metersPerUnit
        self.environmentMapURL = environmentMapURL
        self.environmentExposure = environmentExposure
        self.environmentRotation = environmentRotation
        self.showEnvironmentBackground = showEnvironmentBackground
    }
    
    /// Convert EV exposure to RealityKit's intensityExponent (base-2)
    public var realityKitIntensityExponent: Float {
        // EV uses base-2, intensityExponent uses base-2
        return environmentExposure
    }
}
