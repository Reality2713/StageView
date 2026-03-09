import RealityKit
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

/// Dynamic grid with fixed real-world major spacing and adaptive extent.
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
        let minorThickness = max(Float(0.001 / safeMpu), step * 0.02)
        let axisThickness = minorThickness * 2.6

        for i in -lineCount...lineCount {
            let offset = Float(i) * step
            let distanceRatio = Float(abs(i)) / Float(max(lineCount, 1))
            let isAxisLine = i == 0
            let isMajor = (abs(i) % majorEvery) == 0

            let lineStyle = material(
                isAxisLine: isAxisLine,
                isMajor: isMajor,
                distanceRatio: distanceRatio,
                axis: planeAxisA,
                palette: palette
            )
            let lineA = Entity()
            lineA.components.set(ModelComponent(
                mesh: lineMesh(length: extent * 2, thickness: lineStyle.thickness, axis: planeAxisA),
                materials: [lineStyle.material]
            ))
            lineA.position = offsetPosition(planeAxisB, offset: offset)
            gridRoot.addChild(lineA)

            let lineStyleB = material(
                isAxisLine: isAxisLine,
                isMajor: isMajor,
                distanceRatio: distanceRatio,
                axis: planeAxisB,
                palette: palette
            )
            let lineB = Entity()
            lineB.components.set(ModelComponent(
                mesh: lineMesh(length: extent * 2, thickness: lineStyleB.thickness, axis: planeAxisB),
                materials: [lineStyleB.material]
            ))
            lineB.position = offsetPosition(planeAxisA, offset: offset)
            gridRoot.addChild(lineB)
        }

        let upAxisLen = extent * 0.5
        let upAxisEntity = Entity()
        upAxisEntity.components.set(ModelComponent(
            mesh: lineMesh(length: upAxisLen, thickness: axisThickness, axis: upAxis),
            materials: [axisMaterial(for: upAxis, palette: palette)]
        ))
        upAxisEntity.position = offsetPosition(upAxis, offset: upAxisLen / 2)
        gridRoot.addChild(upAxisEntity)

        return gridRoot
    }

    private static func material(
        isAxisLine: Bool,
        isMajor: Bool,
        distanceRatio: Float,
        axis: Axis,
        palette: GridPalette
    ) -> (material: UnlitMaterial, thickness: Float) {
        if isAxisLine {
            return (axisMaterial(for: axis, palette: palette), palette.axisThickness)
        }
        if isMajor {
            return (
                distanceRatio > 0.72 ? palette.majorFar : palette.majorNear,
                palette.majorThickness
            )
        }
        return (
            distanceRatio > 0.72 ? palette.minorFar : palette.minorNear,
            palette.minorThickness
        )
    }

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

private struct GridPalette {
    let minorNear: UnlitMaterial
    let minorFar: UnlitMaterial
    let majorNear: UnlitMaterial
    let majorFar: UnlitMaterial
    let xAxis: UnlitMaterial
    let yAxis: UnlitMaterial
    let zAxis: UnlitMaterial
    let minorThickness: Float
    let majorThickness: Float
    let axisThickness: Float

    init(appearance: ViewportAppearance) {
        minorThickness = 0.002
        majorThickness = 0.0036
        axisThickness = 0.0052

        switch appearance {
        case .light:
            minorNear = UnlitMaterial(color: PlatformColor(white: 0.42, alpha: 0.18))
            minorFar = UnlitMaterial(color: PlatformColor(white: 0.58, alpha: 0.08))
            majorNear = UnlitMaterial(color: PlatformColor(white: 0.28, alpha: 0.26))
            majorFar = UnlitMaterial(color: PlatformColor(white: 0.38, alpha: 0.14))
            xAxis = UnlitMaterial(color: PlatformColor(red: 0.74, green: 0.18, blue: 0.18, alpha: 0.82))
            yAxis = UnlitMaterial(color: PlatformColor(red: 0.18, green: 0.62, blue: 0.18, alpha: 0.82))
            zAxis = UnlitMaterial(color: PlatformColor(red: 0.18, green: 0.38, blue: 0.82, alpha: 0.82))
        case .dark:
            minorNear = UnlitMaterial(color: PlatformColor(white: 0.56, alpha: 0.26))
            minorFar = UnlitMaterial(color: PlatformColor(white: 0.46, alpha: 0.12))
            majorNear = UnlitMaterial(color: PlatformColor(white: 0.72, alpha: 0.34))
            majorFar = UnlitMaterial(color: PlatformColor(white: 0.62, alpha: 0.18))
            xAxis = UnlitMaterial(color: PlatformColor(red: 0.92, green: 0.24, blue: 0.24, alpha: 0.92))
            yAxis = UnlitMaterial(color: PlatformColor(red: 0.24, green: 0.82, blue: 0.24, alpha: 0.92))
            zAxis = UnlitMaterial(color: PlatformColor(red: 0.24, green: 0.46, blue: 0.96, alpha: 0.92))
        }
    }
}
