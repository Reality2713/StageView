import RealityKit
import OSLog
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

private let gridLogger = Logger(subsystem: "RealityKitStageView", category: "Grid")

/// Single-plane procedural grid driven entirely by a MaterialX shader graph.
/// One quad, zero geometry overhead — the shader computes grid lines, axis
/// colors, depth-modulated thickness, and fog fade per-fragment.
public struct RealityKitGrid {

    public struct Metrics: Sendable, Equatable {
        public let worldExtent: Double
        public let metersPerUnit: Double
        public let worldExtentMeters: Double
        public let radiusMeters: Double
        public let minorStepMeters: Double
        public let majorStepMeters: Double
        public let edgeFadeStartMeters: Double
        public let edgeFadeEndMeters: Double
        public let fogDensity: Float
        public let fogMax: Float
    }

    // MARK: - Public API

    /// Load the procedural grid from the bundled USDA.
    /// Returns a single entity containing one double-sided plane with a
    /// `ShaderGraphMaterial` whose parameters can be mutated at runtime.
    @MainActor
    public static func createProceduralGridEntity(
        metersPerUnit: Double,
        worldExtent: Double,
        isZUp: Bool,
        appearance: ViewportAppearance,
        minorColorOverride: SIMD3<Float>? = nil,
        majorColorOverride: SIMD3<Float>? = nil
    ) async -> Entity? {
        guard let url = Bundle.module.url(
            forResource: "ViewportGrid",
            withExtension: "usda"
        ) else {
            gridLogger.error("ViewportGrid.usda not found in bundle.")
            return nil
        }

        do {
            let entity = try await Entity(contentsOf: url)
            entity.name = "ReferenceGrid"

            updateProceduralGrid(
                entity: entity,
                metersPerUnit: metersPerUnit,
                worldExtent: worldExtent,
                isZUp: isZUp,
                appearance: appearance,
                minorColorOverride: minorColorOverride,
                majorColorOverride: majorColorOverride
            )

            return entity
        } catch {
            gridLogger.error("Failed to load procedural grid: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Update the grid's shader parameters without recreating the entity.
    @MainActor
    public static func updateProceduralGrid(
        entity: Entity,
        metersPerUnit: Double,
        worldExtent: Double,
        isZUp: Bool,
        appearance: ViewportAppearance,
        minorColorOverride: SIMD3<Float>? = nil,
        majorColorOverride: SIMD3<Float>? = nil
    ) {
        _ = isZUp
        let metrics = metrics(
            metersPerUnit: metersPerUnit,
            worldExtent: worldExtent,
            appearance: appearance
        )
        let minorStep = metrics.minorStepMeters
        let majorStep = metrics.majorStepMeters
        let minorStepFloat = Float(minorStep)
        let majorStepFloat = Float(majorStep)
        let radiusMetersFloat = Float(metrics.radiusMeters)

        let minorScale = Float(1.0 / minorStep)
        let majorScale = Float(1.0 / majorStep)
        let axisBaseThicknessWorld = Float(
            min(max(minorStepFloat * 0.012, 0.00008), majorStepFloat * 0.0015)
        )
        let axisDepthFactorWorld = Float(
            min(max(minorStepFloat * 0.0006, 0.00001), majorStepFloat * 0.0001)
        )
        let axisThicknessWorldMax = Float(
            min(max(minorStepFloat * 0.02, 0.00014), majorStepFloat * 0.002)
        )
        let axisHalfLengthWorld = Float(
            max(radiusMetersFloat * 2.0, majorStepFloat * 8.0)
        )
        let axisOpacityScale: Float = 1.15
        // The horizon fade is relative to the total grid radius so the grid
        // reads as a circular field around the model rather than a square plane.
        let edgeFadeStart = Float(metrics.edgeFadeStartMeters)
        let edgeFadeEnd = Float(metrics.edgeFadeEndMeters)
        let edgeFadeReciprocalRange = 1 / max(edgeFadeEnd - edgeFadeStart, 0.0001)

        // Scale the plane to cover the needed world extent.
        // The USDA plane is ±50m (100m total). Scale to match the grid radius.
        let planeHalfExtent: Float = 50.0
        let neededHalfExtent = radiusMetersFloat
        let scaleFactor = max(neededHalfExtent / planeHalfExtent, 0.001)
        entity.scale = SIMD3<Float>(repeating: scaleFactor)

        // RealityKit imports USD scenes into a Y-up world, even when the source
        // stage metadata says Z-up. Keep the procedural floor aligned to the
        // RealityKit world ground plane so it does not double-rotate for Z-up assets.
        // Position is NOT set here — that is the caller's responsibility via alignGrid(),
        // which derives the correct floor Y from the loaded scene's bounds.
        entity.transform.rotation = .init()

        // Resolve colors for appearance, applying any caller-provided overrides.
        let palette = ProceduralGridPalette(appearance: appearance)
        // Keep the shader fog tied to total grid size so large grids do not stay
        // fully crisp out to their hard square edge, and tiny grids do not
        // disappear immediately near the center.
        let fogDensity = metrics.fogDensity
        let fogMax = metrics.fogMax
        let resolvedMinorColor = minorColorOverride ?? palette.minorColor
        let resolvedMajorColor = majorColorOverride ?? palette.majorColor

        gridLogger.notice(
            "viewport_grid_tuning extent_units=\(metrics.worldExtent, format: .fixed(precision: 4)) mpu=\(metrics.metersPerUnit, format: .fixed(precision: 6)) extent_m=\(metrics.worldExtentMeters, format: .fixed(precision: 4)) radius_m=\(metrics.radiusMeters, format: .fixed(precision: 4)) minor_m=\(metrics.minorStepMeters, format: .fixed(precision: 4)) major_m=\(metrics.majorStepMeters, format: .fixed(precision: 4)) fade_start_m=\(metrics.edgeFadeStartMeters, format: .fixed(precision: 4)) fade_end_m=\(metrics.edgeFadeEndMeters, format: .fixed(precision: 4)) fog_density=\(metrics.fogDensity, format: .fixed(precision: 6)) fog_max=\(metrics.fogMax, format: .fixed(precision: 4))"
        )

        // Thickness values live in frac-space. As the world-space step shrinks,
        // scale them up so the on-screen world-space line width stays stable.
        let thicknessScale = Float(1.0 / minorStep)

        // Walk entity tree and set ShaderGraphMaterial parameters.
        setMaterialParameters(
            on: entity,
            minorScale: minorScale,
            majorScale: majorScale,
            axisBaseThicknessWorld: axisBaseThicknessWorld,
            axisDepthFactorWorld: axisDepthFactorWorld,
            axisThicknessWorldMax: axisThicknessWorldMax,
            axisHalfLengthWorld: axisHalfLengthWorld,
            axisOpacityScale: axisOpacityScale,
            minorBaseThickness: palette.minorBaseThickness * thicknessScale,
            majorBaseThickness: palette.majorBaseThickness * thicknessScale,
            fogDensity: fogDensity,
            fogMax: fogMax,
            edgeFadeStart: edgeFadeStart,
            edgeFadeReciprocalRange: edgeFadeReciprocalRange,
            minorColor: resolvedMinorColor,
            majorColor: resolvedMajorColor,
            xAxisColor: palette.xAxisColor,
            zAxisColor: palette.zAxisColor,
            baseOpacity: palette.baseOpacity,
            lineOpacityScale: palette.lineOpacityScale
        )
    }

    // MARK: - Material parameter wiring

    @MainActor
    private static func setMaterialParameters(
        on entity: Entity,
        minorScale: Float,
        majorScale: Float,
        axisBaseThicknessWorld: Float,
        axisDepthFactorWorld: Float,
        axisThicknessWorldMax: Float,
        axisHalfLengthWorld: Float,
        axisOpacityScale: Float,
        minorBaseThickness: Float,
        majorBaseThickness: Float,
        fogDensity: Float,
        fogMax: Float,
        edgeFadeStart: Float,
        edgeFadeReciprocalRange: Float,
        minorColor: SIMD3<Float>,
        majorColor: SIMD3<Float>,
        xAxisColor: SIMD3<Float>,
        zAxisColor: SIMD3<Float>,
        baseOpacity: Float,
        lineOpacityScale: Float
    ) {
        guard var model = entity.components[ModelComponent.self] else {
            for child in entity.children {
                setMaterialParameters(
                    on: child,
                    minorScale: minorScale,
                    majorScale: majorScale,
                    axisBaseThicknessWorld: axisBaseThicknessWorld,
                    axisDepthFactorWorld: axisDepthFactorWorld,
                    axisThicknessWorldMax: axisThicknessWorldMax,
                    axisHalfLengthWorld: axisHalfLengthWorld,
                    axisOpacityScale: axisOpacityScale,
                    minorBaseThickness: minorBaseThickness,
                    majorBaseThickness: majorBaseThickness,
                    fogDensity: fogDensity,
                    fogMax: fogMax,
                    edgeFadeStart: edgeFadeStart,
                    edgeFadeReciprocalRange: edgeFadeReciprocalRange,
                    minorColor: minorColor,
                    majorColor: majorColor,
                    xAxisColor: xAxisColor,
                    zAxisColor: zAxisColor,
                    baseOpacity: baseOpacity,
                    lineOpacityScale: lineOpacityScale
                )
            }
            return
        }

        var materials = model.materials
        for i in materials.indices {
            guard var sgMaterial = materials[i] as? ShaderGraphMaterial else { continue }

            do {
                try sgMaterial.setParameter(name: "minorScale", value: .float(minorScale))
                try sgMaterial.setParameter(name: "majorScale", value: .float(majorScale))
                try sgMaterial.setParameter(name: "axisBaseThicknessWorld", value: .float(axisBaseThicknessWorld))
                try sgMaterial.setParameter(name: "axisDepthFactorWorld", value: .float(axisDepthFactorWorld))
                try sgMaterial.setParameter(name: "axisThicknessWorldMax", value: .float(axisThicknessWorldMax))
                try sgMaterial.setParameter(name: "axisHalfLengthWorld", value: .float(axisHalfLengthWorld))
                try sgMaterial.setParameter(name: "axisOpacityScale", value: .float(axisOpacityScale))
                try sgMaterial.setParameter(name: "minorBaseThickness", value: .float(minorBaseThickness))
                try sgMaterial.setParameter(name: "majorBaseThickness", value: .float(majorBaseThickness))
                try sgMaterial.setParameter(name: "fogDensity", value: .float(fogDensity))
                try sgMaterial.setParameter(name: "fogMax", value: .float(fogMax))
                try sgMaterial.setParameter(name: "edgeFadeStart", value: .float(edgeFadeStart))
                try sgMaterial.setParameter(name: "edgeFadeReciprocalRange", value: .float(edgeFadeReciprocalRange))
                try sgMaterial.setParameter(name: "baseOpacity", value: .float(baseOpacity))
                try sgMaterial.setParameter(name: "lineOpacityScale", value: .float(lineOpacityScale))
                try sgMaterial.setParameter(name: "minorColor", value: .color(cgColor(minorColor)))
                try sgMaterial.setParameter(name: "majorColor", value: .color(cgColor(majorColor)))
                try sgMaterial.setParameter(name: "xAxisColor", value: .color(cgColor(xAxisColor)))
                try sgMaterial.setParameter(name: "zAxisColor", value: .color(cgColor(zAxisColor)))
            } catch {
                gridLogger.warning("Failed to set grid material parameter: \(error.localizedDescription, privacy: .public)")
            }

            materials[i] = sgMaterial
        }

        model.materials = materials
        entity.components.set(model)
    }

    private static func cgColor(_ v: SIMD3<Float>) -> CGColor {
        CGColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
    }

    public static func metrics(
        metersPerUnit: Double,
        worldExtent: Double,
        appearance: ViewportAppearance
    ) -> Metrics {
        let safeMetersPerUnit = Swift.max(metersPerUnit, 0.000_001)
        let worldExtentMeters = worldExtent * safeMetersPerUnit
        let radiusMeters = ViewportTuning.gridRadiusMeters(worldExtentMeters: worldExtentMeters)
        let minorStep = ViewportTuning.minorGridStepMeters(forGridRadius: radiusMeters)
        let majorStep = ViewportTuning.majorGridStepMeters(forMinorStep: minorStep)
        let palette = ProceduralGridPalette(appearance: appearance)
        let radiusMetersFloat = Float(radiusMeters)
        let fogDensity = palette.fogDensity / max(radiusMetersFloat, 1.0)
        let fogMax = palette.fogMax
        return Metrics(
            worldExtent: worldExtent,
            metersPerUnit: safeMetersPerUnit,
            worldExtentMeters: worldExtentMeters,
            radiusMeters: radiusMeters,
            minorStepMeters: minorStep,
            majorStepMeters: majorStep,
            edgeFadeStartMeters: radiusMeters * (2.0 / 3.0),
            edgeFadeEndMeters: radiusMeters,
            fogDensity: fogDensity,
            fogMax: fogMax
        )
    }
}

// MARK: - Color palette

struct ProceduralGridPalette {
    let minorColor: SIMD3<Float>
    let majorColor: SIMD3<Float>
    let xAxisColor: SIMD3<Float>
    let zAxisColor: SIMD3<Float>
    let minorBaseThickness: Float
    let majorBaseThickness: Float
    let fogDensity: Float
    let fogMax: Float
    let baseOpacity: Float
    let lineOpacityScale: Float

    init(appearance: ViewportAppearance) {
        switch appearance {
        case .dark:
            minorColor = SIMD3<Float>(0.34, 0.37, 0.42)
            majorColor = SIMD3<Float>(0.44, 0.47, 0.51)
            // AxisX covers the line at X=0 (Z-axis), AxisZ covers the line at Z=0 (X-axis).
            // Swap so the convention matches the gizmo: X=red, Z=blue.
            xAxisColor = SIMD3<Float>(0.0, 0.0, 1.0) // Blue → Z-axis line (at X=0)
            zAxisColor = SIMD3<Float>(1.0, 0.0, 0.0) // Red  → X-axis line (at Z=0)
            minorBaseThickness = 0.0016
            majorBaseThickness = 0.0011
            fogDensity = 0.16
            fogMax = 0.985
            baseOpacity = 0
            lineOpacityScale = 0.96

        case .light:
            minorColor = SIMD3<Float>(0.42, 0.44, 0.48)
            majorColor = SIMD3<Float>(0.24, 0.26, 0.30)
            xAxisColor = SIMD3<Float>(0.0, 0.0, 1.0) // Blue → Z-axis line (at X=0)
            zAxisColor = SIMD3<Float>(1.0, 0.0, 0.0) // Red  → X-axis line (at Z=0)
            minorBaseThickness = 0.0014
            majorBaseThickness = 0.00095
            fogDensity = 0.11
            fogMax = 0.97
            baseOpacity = 0
            lineOpacityScale = 0.97
        }
    }
}
