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
    /// Legacy compatibility input for non-store integrations.
    ///
    /// TCA-first hosts should drive mutable per-viewport IBL through
    /// `StageViewFeature.State.environmentURL` instead of this property.
    public var environmentMapURL: URL?
    /// Normalized blur amount for generated soft-reflection HDRs.
    /// `0` preserves the sharp authored map, `1` applies the default soft blur.
    public var environmentBlurAmount: Float = 1.0
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
        environmentBlurAmount: Float = 1.0,
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
        self.environmentBlurAmount = environmentBlurAmount
        self.environmentExposure = environmentExposure
        self.environmentRotation = environmentRotation
        self.showEnvironmentBackground = showEnvironmentBackground
        self.outlineConfiguration = outlineConfiguration
        self.selectionHighlightStyle = selectionHighlightStyle
        self.showOrientationGizmo = showOrientationGizmo
        self.showScaleIndicator = showScaleIndicator
    }

    /// Treat StageView exposure as a direct stop offset over the authored HDR
    /// environment intensity. A value of 0 uses the environment as-authored,
    /// +1 doubles the contribution, and -1 halves it.
    private static func realityKitMappedEV(forHydraEV ev: Float) -> Float {
        ev
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

    /// Returns true if any built-in overlays should be rendered.
    public var showsBuiltInOverlays: Bool {
        showOrientationGizmo || showScaleIndicator
    }
}
