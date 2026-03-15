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
    public var navigationMapping: RealityKitNavigationMapping = .apple

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
        selectionHighlightStyle: SelectionHighlightStyle = .boundingBox,
        navigationMapping: RealityKitNavigationMapping = .apple
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
        self.navigationMapping = navigationMapping
    }

    /// Hydra canonical EV model: linear gain = 2^EV.
    public static func hydraLinearExposureGain(forEV ev: Float) -> Float {
        let rkEV = realityKitMappedEV(forHydraEV: ev)
        return powf(2.0, rkEV)
    }

    /// RealityKit's `intensityExponent` is EV-like (base-2 exponent), so this
    /// maps 1:1 from Hydra EV.
    public static func realityKitIntensityExponent(forHydraEV ev: Float) -> Float {
        realityKitMappedEV(forHydraEV: ev)
    }

    /// RealityKit drifts at the slider's top end; compress only the tail while
    /// keeping the rest aligned with Hydra EV.
    private static func realityKitMappedEV(forHydraEV ev: Float) -> Float {
        let softKneeStart: Float = 2.7
        guard ev > softKneeStart else { return ev }
        return softKneeStart + (ev - softKneeStart) * 0.5
    }

    public var hydraLinearExposureGain: Float {
        Self.hydraLinearExposureGain(forEV: environmentExposure)
    }

    public var realityKitIntensityExponent: Float {
        Self.realityKitIntensityExponent(forHydraEV: environmentExposure)
    }
}
