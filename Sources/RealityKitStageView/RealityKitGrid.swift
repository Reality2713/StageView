import RealityKit

/// Dynamic grid with scale awareness that matches Hydra renderer behavior.
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
        isZUp: Bool
    ) -> Entity {
        let gridRoot = Entity()
        gridRoot.name = "ReferenceGrid"

        let upAxis: Axis = isZUp ? .z : .y
        let planeAxisA: Axis = .x
        let planeAxisB: Axis = isZUp ? .y : .z

        // Position slightly below ground to prevent z-fighting
        gridRoot.position = offsetPosition(upAxis, offset: -0.001)

        let mpu = metersPerUnit > 0 ? metersPerUnit : 0.01
        let oneMeter = Float(1.0 / mpu)  // Scene units per real meter

        // Extend grid based on world size (min 10m, or 1.5x scene)
        let radiusMeters = Float(max(10.0, worldExtent * mpu * 1.5))
        let unitCount = Int(ceil(radiusMeters))
        let axisLen = Float(unitCount) * oneMeter

        // Materials
        let gridMaterial = UnlitMaterial(color: .gray.withAlphaComponent(0.3))
        let xAxisMaterial = UnlitMaterial(color: .red.withAlphaComponent(0.8))
        let yAxisMaterial = UnlitMaterial(color: .green.withAlphaComponent(0.8))
        let zAxisMaterial = UnlitMaterial(color: .blue.withAlphaComponent(0.8))

        let lineThickness: Float = 0.002

        // Grid lines along planeAxisA (offset along planeAxisB)
        for i in -unitCount...unitCount {
            let offset = Float(i) * oneMeter
            let isAxisLine = i == 0

            let material = isAxisLine
                ? axisMaterial(
                    for: planeAxisA,
                    xAxisMaterial: xAxisMaterial,
                    yAxisMaterial: yAxisMaterial,
                    zAxisMaterial: zAxisMaterial
                )
                : gridMaterial

            let entity = Entity()
            entity.components.set(ModelComponent(
                mesh: lineMesh(length: axisLen * 2, thickness: lineThickness, axis: planeAxisA),
                materials: [material]
            ))
            entity.position = offsetPosition(planeAxisB, offset: offset)
            gridRoot.addChild(entity)
        }

        // Grid lines along planeAxisB (offset along planeAxisA)
        for i in -unitCount...unitCount {
            let offset = Float(i) * oneMeter
            let isAxisLine = i == 0

            let material = isAxisLine
                ? axisMaterial(
                    for: planeAxisB,
                    xAxisMaterial: xAxisMaterial,
                    yAxisMaterial: yAxisMaterial,
                    zAxisMaterial: zAxisMaterial
                )
                : gridMaterial

            let entity = Entity()
            entity.components.set(ModelComponent(
                mesh: lineMesh(length: axisLen * 2, thickness: lineThickness, axis: planeAxisB),
                materials: [material]
            ))
            entity.position = offsetPosition(planeAxisA, offset: offset)
            gridRoot.addChild(entity)
        }

        // Up axis line
        let upAxisLen = axisLen * 0.5
        let upAxisEntity = Entity()
        upAxisEntity.components.set(ModelComponent(
            mesh: lineMesh(length: upAxisLen, thickness: lineThickness, axis: upAxis),
            materials: [axisMaterial(
                for: upAxis,
                xAxisMaterial: xAxisMaterial,
                yAxisMaterial: yAxisMaterial,
                zAxisMaterial: zAxisMaterial
            )]
        ))
        upAxisEntity.position = offsetPosition(upAxis, offset: upAxisLen / 2)
        gridRoot.addChild(upAxisEntity)

        return gridRoot
    }

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

    private static func axisMaterial(
        for axis: Axis,
        xAxisMaterial: UnlitMaterial,
        yAxisMaterial: UnlitMaterial,
        zAxisMaterial: UnlitMaterial
    ) -> UnlitMaterial {
        switch axis {
        case .x:
            return xAxisMaterial
        case .y:
            return yAxisMaterial
        case .z:
            return zAxisMaterial
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
