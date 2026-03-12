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
        appearance: ViewportAppearance
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
                appearance: appearance
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
        appearance: ViewportAppearance
    ) {
        let safeMpu = metersPerUnit > 0 ? metersPerUnit : 1.0
        let worldExtentMeters = worldExtent * safeMpu
        let radiusMeters = ViewportTuning.gridRadiusMeters(worldExtentMeters: worldExtentMeters)
        let minorStep = ViewportTuning.minorGridStepMeters(forGridRadius: radiusMeters)

        let minorScale = Float(1.0 / minorStep)
        let majorScale: Float = 1.0

        // Scale the plane to cover the needed world extent.
        // The USDA plane is ±50m (100m total). Scale to match the grid radius.
        let planeHalfExtent: Float = 50.0
        let neededHalfExtent = Float(radiusMeters / safeMpu)
        let scaleFactor = max(neededHalfExtent / planeHalfExtent, 0.01)
        entity.scale = SIMD3<Float>(repeating: scaleFactor)

        // Position slightly below ground to prevent z-fighting.
        let yOffset = Float(-0.001 / safeMpu)
        if isZUp {
            entity.transform.rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            entity.position = SIMD3<Float>(0, 0, -yOffset)
        } else {
            entity.transform.rotation = .init()
            entity.position = SIMD3<Float>(0, yOffset, 0)
        }

        // Resolve colors for appearance.
        let palette = ProceduralGridPalette(appearance: appearance)

        // Walk entity tree and set ShaderGraphMaterial parameters.
        setMaterialParameters(
            on: entity,
            minorScale: minorScale,
            majorScale: majorScale,
            fogDensity: palette.fogDensity,
            fogMax: palette.fogMax,
            minorColor: palette.minorColor,
            majorColor: palette.majorColor,
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
        fogDensity: Float,
        fogMax: Float,
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
                    fogDensity: fogDensity,
                    fogMax: fogMax,
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
                try sgMaterial.setParameter(name: "fogDensity", value: .float(fogDensity))
                try sgMaterial.setParameter(name: "fogMax", value: .float(fogMax))
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
    let fogDensity: Float
    let fogMax: Float
    let baseOpacity: Float
    let lineOpacityScale: Float

    init(appearance: ViewportAppearance) {
        switch appearance {
        case .dark:
            minorColor = SIMD3<Float>(0.34, 0.37, 0.42)
            majorColor = SIMD3<Float>(0.50, 0.53, 0.57)
            xAxisColor = SIMD3<Float>(0.32, 0.58, 0.87)
            zAxisColor = SIMD3<Float>(0.72, 0.49, 0.31)
            fogDensity = 0.065
            fogMax = 0.90
            baseOpacity = 0.014
            lineOpacityScale = 0.99

        case .light:
            minorColor = SIMD3<Float>(0.55, 0.58, 0.62)
            majorColor = SIMD3<Float>(0.42, 0.45, 0.49)
            xAxisColor = SIMD3<Float>(0.37, 0.61, 0.83)
            zAxisColor = SIMD3<Float>(0.72, 0.54, 0.40)
            fogDensity = 0.038
            fogMax = 0.68
            baseOpacity = 0.012
            lineOpacityScale = 0.99
        }
    }
}
