import Foundation
import RealityKit
import SwiftUI

/// Selection visualization mode.
public enum SelectionHighlightStyle: Sendable, Equatable {
    /// Inverted-hull mesh outline based on surface normals.
    case outline
    /// Axis-aligned wireframe bounds cage around the selected entity/subtree.
    case boundingBox
    /// Screen-space post-process outline. Pixel-perfect and scale-independent.
    /// Requires macOS 26 / iOS 26 / tvOS 26. Falls back to `.outline` on earlier OS versions.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
    @available(visionOS, unavailable)
    case postProcessOutline
    /// Disable selection highlighting.
    case none
}

/// Configuration for the RealityKit viewport.
///
/// `RealityKitConfiguration` is reserved for static embedding concerns and
/// renderer options. Mutable appearance intent belongs in
/// `StageViewFeature.State.appearance`.
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

    /// Whether the built-in orientation gizmo (bottom-left XYZ axes) is rendered.
    /// Set to `false` when the consumer renders its own gizmo outside the Metal surface
    /// so that SwiftUI glass materials can sample the composited viewport correctly.
    public var showOrientationGizmo: Bool = true

    /// Whether the built-in scale indicator (top-center ruler bar) is rendered.
    /// Set to `false` for the same reason as `showOrientationGizmo`.
    public var showScaleIndicator: Bool = true

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
        showOrientationGizmo: Bool = true,
        showScaleIndicator: Bool = true
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
        self.showOrientationGizmo = showOrientationGizmo
        self.showScaleIndicator = showScaleIndicator
    }

    /// RealityKit currently renders hotter than Hydra for the same EV slider
    /// value, so both the IBL exponent and visible skybox gain need the same
    /// calibration before applying the base-2 multiplier.
    private static func realityKitMappedEV(forHydraEV ev: Float) -> Float {
        let baselineOffset: Float = -1.0
        let calibratedEV = ev + baselineOffset

        // Keep the previous high-end protection so the top of the slider
        // still does not run away once the baseline is corrected.
        let softKneeStart: Float = 2.7
        let kneeAdjustedEV: Float
        if calibratedEV > softKneeStart {
            kneeAdjustedEV = softKneeStart + (calibratedEV - softKneeStart) * 0.5
        } else {
            kneeAdjustedEV = calibratedEV
        }

        // RealityKit becomes unstable near the top of the slider and can
        // effectively reset exposure, so cap the mapped exponent below that
        // threshold for both the IBL and visible skybox.
        let maxStableEV: Float = 1.8
        return min(kneeAdjustedEV, maxStableEV)
    }

    /// Linear gain from EV after RealityKit-specific calibration. Used for skybox tint.
    public static func hydraLinearExposureGain(forEV ev: Float) -> Float {
        powf(2.0, realityKitMappedEV(forHydraEV: ev))
    }

    /// RealityKit's `intensityExponent` is a base-2 exponent.
    public static func realityKitIntensityExponent(forHydraEV ev: Float) -> Float {
        realityKitMappedEV(forHydraEV: ev)
    }

    public var hydraLinearExposureGain: Float {
        Self.hydraLinearExposureGain(forEV: environmentExposure)
    }

    public var realityKitIntensityExponent: Float {
        Self.realityKitIntensityExponent(forHydraEV: environmentExposure)
    }
}
