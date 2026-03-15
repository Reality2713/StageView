import Foundation
import RealityKit
import SwiftUI

/// Selection visualization mode.
public enum SelectionHighlightStyle: Sendable, Equatable {
    /// Inverted-hull mesh outline based on surface normals.
    case outline
    /// Axis-aligned wireframe bounds cage around the selected entity/subtree.
    case boundingBox
    /// Disable selection highlighting.
    case none
}

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
    /// Rendering mode for selection visualization.
    public var selectionHighlightStyle: SelectionHighlightStyle = .boundingBox

    public init(
        showGrid: Bool = true,
        showAxes: Bool = true,
        metersPerUnit: Double = 1.0,
        isZUp: Bool = false,
        environmentMapURL: URL? = nil,
        environmentExposure: Float = 0.0,
        environmentRotation: Float = 0.0,
        showEnvironmentBackground: Bool = true,
        outlineConfiguration: OutlineConfiguration = .init(),
        selectionHighlightStyle: SelectionHighlightStyle = .boundingBox
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
        self.selectionHighlightStyle = selectionHighlightStyle
    }

    /// Linear gain from EV: 2^EV. Used for skybox tint.
    public static func hydraLinearExposureGain(forEV ev: Float) -> Float {
        powf(2.0, ev)
    }

    /// RealityKit's `intensityExponent` is a base-2 exponent (same as Hydra EV).
    /// Straight pass-through — both engines use `2^EV` as the effective multiplier.
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
