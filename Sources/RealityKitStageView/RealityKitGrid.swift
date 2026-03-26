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
        let worldExtentMeters = worldExtent // Already in Meters from runtime
        let radiusMeters = ViewportTuning.gridRadiusMeters(worldExtentMeters: worldExtentMeters)
        let minorStep = ViewportTuning.minorGridStepMeters(forGridRadius: radiusMeters)

        let minorScale = Float(1.0 / minorStep)
        let majorScale: Float = 1.0
        let edgeFadeStart = Float(radiusMeters * 0.8)
        let edgeFadeEnd = Float(radiusMeters * 0.995)
        let edgeFadeReciprocalRange = 1 / max(edgeFadeEnd - edgeFadeStart, 0.0001)

        // Scale the plane to cover the needed world extent.
        // The USDA plane is ±50m (100m total). Scale to match the grid radius.
        let planeHalfExtent: Float = 50.0
        let neededHalfExtent = Float(radiusMeters)
        let scaleFactor = max(neededHalfExtent / planeHalfExtent, 0.001)
        entity.scale = SIMD3<Float>(repeating: scaleFactor)

        // RealityKit imports USD scenes into a Y-up world, even when the source
        // stage metadata says Z-up. Keep the procedural floor aligned to the
        // RealityKit world ground plane so it does not double-rotate for Z-up assets.
        let yOffset = Float(-0.001)
        entity.transform.rotation = .init()
        entity.position = SIMD3<Float>(0, yOffset, 0)

        // Resolve colors for appearance, applying any caller-provided overrides.
        let palette = ProceduralGridPalette(appearance: appearance)
        let resolvedMinorColor = minorColorOverride ?? palette.minorColor
        let resolvedMajorColor = majorColorOverride ?? palette.majorColor

        // Scale thicknesses relative to the grid resolution.
        // The palette base values are balanced for a 1m grid.
        let thicknessScale = Float(minorStep)

        // Walk entity tree and set ShaderGraphMaterial parameters.
        setMaterialParameters(
            on: entity,
            minorScale: minorScale,
            majorScale: majorScale,
            minorBaseThickness: palette.minorBaseThickness * thicknessScale,
            majorBaseThickness: palette.majorBaseThickness * thicknessScale,
            axisExtraThickness: palette.axisExtraThickness * thicknessScale,
            fogDensity: palette.fogDensity,
            fogMax: palette.fogMax,
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
        minorBaseThickness: Float,
        majorBaseThickness: Float,
        axisExtraThickness: Float,
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
                    minorBaseThickness: minorBaseThickness,
                    majorBaseThickness: majorBaseThickness,
                    axisExtraThickness: axisExtraThickness,
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
                try sgMaterial.setParameter(name: "minorBaseThickness", value: .float(minorBaseThickness))
                try sgMaterial.setParameter(name: "majorBaseThickness", value: .float(majorBaseThickness))
                try sgMaterial.setParameter(name: "axisExtraThickness", value: .float(axisExtraThickness))
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
}

// MARK: - Color palette

struct ProceduralGridPalette {
    let minorColor: SIMD3<Float>
    let majorColor: SIMD3<Float>
    let xAxisColor: SIMD3<Float>
    let zAxisColor: SIMD3<Float>
    let minorBaseThickness: Float
    let majorBaseThickness: Float
    let axisExtraThickness: Float
    let fogDensity: Float
    let fogMax: Float
    let baseOpacity: Float
    let lineOpacityScale: Float

    init(appearance: ViewportAppearance) {
        switch appearance {
        case .dark:
            minorColor = SIMD3<Float>(0.34, 0.37, 0.42)
            majorColor = SIMD3<Float>(0.44, 0.47, 0.51)
            xAxisColor = SIMD3<Float>(0.84, 0.24, 0.24) // Red-ish
            zAxisColor = SIMD3<Float>(0.24, 0.50, 0.84) // Blue-ish
            minorBaseThickness = 0.0024
            majorBaseThickness = 0.0056
            axisExtraThickness = 0.00018
            fogDensity = 0.12
            fogMax = 0.94
            baseOpacity = 0.014
            lineOpacityScale = 0.96

        case .light:
            minorColor = SIMD3<Float>(0.60, 0.62, 0.65)
            majorColor = SIMD3<Float>(0.44, 0.46, 0.50)
            xAxisColor = SIMD3<Float>(0.76, 0.18, 0.18) // Red-ish
            zAxisColor = SIMD3<Float>(0.18, 0.44, 0.76) // Blue-ish
            minorBaseThickness = 0.0021
            majorBaseThickness = 0.0048
            axisExtraThickness = 0.00015
            fogDensity = 0.07
            fogMax = 0.86
            baseOpacity = 0.016
            lineOpacityScale = 0.97
        }
    }
}
