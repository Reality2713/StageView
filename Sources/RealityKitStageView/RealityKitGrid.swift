import RealityKit
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

/// Dynamic grid with fixed real-world major spacing, smooth distance fade, and
/// hairline axis markers inspired by Reality Composer Pro / Blender / Plasticity.
public struct RealityKitGrid {
    private enum Axis {
        case x
        case y
        case z
    }

    @MainActor
    public static func createGridEntity(
        metersPerUnit: Double,
        worldExtent: Double,
        isZUp: Bool,
        appearance: ViewportAppearance
    ) -> Entity {
        let gridRoot = Entity()
        gridRoot.name = "ReferenceGrid"

        let upAxis: Axis = isZUp ? .z : .y
        let planeAxisA: Axis = .x
        let planeAxisB: Axis = isZUp ? .y : .z

        let safeMpu = metersPerUnit > 0 ? metersPerUnit : 1.0
        let radiusMeters = ViewportTuning.gridRadiusMeters(worldExtentMeters: worldExtent)
        let minorStepMeters = ViewportTuning.minorGridStepMeters(forGridRadius: radiusMeters)
        let majorStepMeters = 1.0
        let majorEvery = max(1, Int((majorStepMeters / minorStepMeters).rounded()))
        let lineCount = max(1, Int(ceil(radiusMeters / minorStepMeters)))

        let extent = Float(radiusMeters / safeMpu)
        let step = Float(minorStepMeters / safeMpu)

        // Position slightly below ground to prevent z-fighting.
        gridRoot.position = offsetPosition(upAxis, offset: -Float(0.001 / safeMpu))

        let palette = GridPalette(appearance: appearance)

        // Axis markers: proportional but capped to stay subtle.
        let axisMarkerLengthMeters = min(
            max(worldExtent * 1.5, 0.1),
            radiusMeters * 0.6
        )

        // --- Thickness ---
        // Grid lines: keep existing adaptive logic.
        let minorThickness = max(Float(0.0002 / safeMpu), min(step * 0.01, extent * 0.0025))
        let majorThickness = max(minorThickness * 1.6, min(step * 0.016, extent * 0.004))
        // Axis markers: hairline — just slightly thicker than major grid lines.
        let axisThickness = max(majorThickness * 1.2, min(step * 0.012, extent * 0.003))

        // --- Grid lines with smooth distance fade ---
        let fadeBands = palette.fadeBands
        for i in -lineCount...lineCount {
            let offset = Float(i) * step
            let distanceRatio = Float(abs(i)) / Float(max(lineCount, 1))
            let isMajor = (abs(i) % majorEvery) == 0

            let thickness = isMajor ? majorThickness : minorThickness
            let material = fadedMaterial(
                isMajor: isMajor,
                distanceRatio: distanceRatio,
                bands: fadeBands
            )

            let lineA = Entity()
            lineA.components.set(ModelComponent(
                mesh: lineMesh(length: extent * 2, thickness: thickness, axis: planeAxisA),
                materials: [material]
            ))
            lineA.position = offsetPosition(planeAxisB, offset: offset)
            gridRoot.addChild(lineA)

            let lineB = Entity()
            lineB.components.set(ModelComponent(
                mesh: lineMesh(length: extent * 2, thickness: thickness, axis: planeAxisB),
                materials: [material]
            ))
            lineB.position = offsetPosition(planeAxisA, offset: offset)
            gridRoot.addChild(lineB)
        }

        // --- Axis markers (hairline, muted) ---
        let axisMarkerLength = Float(axisMarkerLengthMeters / safeMpu)
        let xAxisEntity = Entity()
        xAxisEntity.components.set(ModelComponent(
            mesh: lineMesh(length: axisMarkerLength, thickness: axisThickness, axis: .x),
            materials: [palette.xAxis]
        ))
        gridRoot.addChild(xAxisEntity)

        let floorSecondaryAxisEntity = Entity()
        floorSecondaryAxisEntity.components.set(ModelComponent(
            mesh: lineMesh(length: axisMarkerLength, thickness: axisThickness, axis: planeAxisB),
            materials: [axisMaterial(for: planeAxisB, palette: palette)]
        ))
        gridRoot.addChild(floorSecondaryAxisEntity)

        let upAxisEntity = Entity()
        upAxisEntity.components.set(ModelComponent(
            mesh: lineMesh(length: axisMarkerLength, thickness: axisThickness, axis: upAxis),
            materials: [axisMaterial(for: upAxis, palette: palette)]
        ))
        gridRoot.addChild(upAxisEntity)

        return gridRoot
    }

    // MARK: - Smooth distance fade

    /// Select a material from pre-built fade bands based on distance ratio.
    private static func fadedMaterial(
        isMajor: Bool,
        distanceRatio: Float,
        bands: GridPalette.FadeBands
    ) -> UnlitMaterial {
        let materials = isMajor ? bands.major : bands.minor
        // Map distanceRatio [0..1] → band index.
        let idx = min(Int(distanceRatio * Float(materials.count)), materials.count - 1)
        return materials[max(0, idx)]
    }

    // MARK: - Geometry helpers

    @MainActor
    private static func lineMesh(length: Float, thickness: Float, axis: Axis) -> MeshResource {
        switch axis {
        case .x:
            return MeshResource.generateBox(width: length, height: thickness, depth: thickness)
        case .y:
            return MeshResource.generateBox(width: thickness, height: length, depth: thickness)
        case .z:
            return MeshResource.generateBox(width: thickness, height: thickness, depth: length)
        }
    }

    private static func axisMaterial(for axis: Axis, palette: GridPalette) -> UnlitMaterial {
        switch axis {
        case .x:
            return palette.xAxis
        case .y:
            return palette.yAxis
        case .z:
            return palette.zAxis
        }
    }

    private static func offsetPosition(_ axis: Axis, offset: Float) -> SIMD3<Float> {
        switch axis {
        case .x:
            return SIMD3<Float>(offset, 0, 0)
        case .y:
            return SIMD3<Float>(0, offset, 0)
        case .z:
            return SIMD3<Float>(0, 0, offset)
        }
    }
}

// MARK: - Color palette

private struct GridPalette {
    let xAxis: UnlitMaterial
    let yAxis: UnlitMaterial
    let zAxis: UnlitMaterial

    /// Pre-built materials for smooth distance-based fade (5 bands from center → edge).
    let fadeBands: FadeBands

    struct FadeBands {
        let minor: [UnlitMaterial]
        let major: [UnlitMaterial]
    }

    init(appearance: ViewportAppearance) {
        switch appearance {
        case .light:
            // Axis colors: muted, hairline weight — inspired by RCP light mode.
            xAxis = UnlitMaterial(color: PlatformColor(red: 0.62, green: 0.22, blue: 0.22, alpha: 0.50))
            yAxis = UnlitMaterial(color: PlatformColor(red: 0.22, green: 0.52, blue: 0.22, alpha: 0.50))
            zAxis = UnlitMaterial(color: PlatformColor(red: 0.22, green: 0.34, blue: 0.68, alpha: 0.50))

            fadeBands = FadeBands(
                minor: Self.buildBands(white: 0.42, alphaRange: 0.16...0.02),
                major: Self.buildBands(white: 0.28, alphaRange: 0.24...0.04)
            )

        case .dark:
            // Axis colors: softer than before, still readable.
            xAxis = UnlitMaterial(color: PlatformColor(red: 0.82, green: 0.28, blue: 0.28, alpha: 0.55))
            yAxis = UnlitMaterial(color: PlatformColor(red: 0.28, green: 0.72, blue: 0.28, alpha: 0.55))
            zAxis = UnlitMaterial(color: PlatformColor(red: 0.28, green: 0.44, blue: 0.88, alpha: 0.55))

            fadeBands = FadeBands(
                minor: Self.buildBands(white: 0.54, alphaRange: 0.22...0.03),
                major: Self.buildBands(white: 0.70, alphaRange: 0.30...0.05)
            )
        }
    }

    /// Build 5 materials with linearly interpolated alpha from center (max) to edge (min).
    private static func buildBands(
        white: CGFloat,
        alphaRange: ClosedRange<CGFloat>,
        count: Int = 5
    ) -> [UnlitMaterial] {
        (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(max(count - 1, 1))
            let alpha = alphaRange.lowerBound + (alphaRange.upperBound - alphaRange.lowerBound) * t
            return UnlitMaterial(color: PlatformColor(white: white, alpha: alpha))
        }
    }
}
