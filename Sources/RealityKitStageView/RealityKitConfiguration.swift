import Foundation
import RealityKit
import SwiftUI

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

    /// Appearance for selection outlines.
    public var outlineConfiguration: OutlineConfiguration = .init()

    public init(
        showGrid: Bool = true,
        showAxes: Bool = true,
        metersPerUnit: Double = 1.0,
        isZUp: Bool = false,
        environmentMapURL: URL? = nil,
        environmentExposure: Float = 0.0,
        environmentRotation: Float = 0.0,
        showEnvironmentBackground: Bool = true,
        outlineConfiguration: OutlineConfiguration = .init()
    ) {
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.environmentMapURL = environmentMapURL
        self.environmentExposure = environmentExposure
        self.environmentRotation = environmentRotation
        self.showEnvironmentBackground = showEnvironmentBackground
        self.outlineConfiguration = outlineConfiguration
    }

    /// Hydra canonical EV model: linear gain = 2^EV.
    public static func hydraLinearExposureGain(forEV ev: Float) -> Float {
        powf(2.0, ev)
    }

    /// RealityKit's `intensityExponent` is EV-like (base-2 exponent), so this
    /// maps 1:1 from Hydra EV.
    public static func realityKitIntensityExponent(forHydraEV ev: Float) -> Float {
        ev
    }

    public var hydraLinearExposureGain: Float {
        Self.hydraLinearExposureGain(forEV: environmentExposure)
    }

    public var realityKitIntensityExponent: Float {
        Self.realityKitIntensityExponent(forHydraEV: environmentExposure)
    }
}
