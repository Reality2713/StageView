import RealityKit
import StageViewCore

/// Dynamic grid with scale awareness that matches Hydra renderer behavior.
public struct RealityKitGrid {
    @MainActor
    public static func createGridEntity(
        metersPerUnit: Double,
        worldExtent: Double,
        isZUp: Bool
    ) -> Entity {
        let gridRoot = Entity()
        gridRoot.name = "ReferenceGrid"

        // Position slightly below ground to prevent z-fighting
        gridRoot.position.y = -0.001

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

        // Create grid lines along X axis (lines parallel to Z)
        for i in -unitCount...unitCount {
            let offset = Float(i) * oneMeter
            let isAxisLine = i == 0

            let mesh = MeshResource.generateBox(
                width: axisLen * 2,
                height: lineThickness,
                depth: lineThickness
            )

            var material = gridMaterial
            if isAxisLine {
                material = zAxisMaterial
            }

            let entity = Entity()
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.position = SIMD3<Float>(0, 0, offset)
            gridRoot.addChild(entity)
        }

        // Create grid lines along Z axis (lines parallel to X)
        for i in -unitCount...unitCount {
            let offset = Float(i) * oneMeter
            let isAxisLine = i == 0

            let mesh = MeshResource.generateBox(
                width: lineThickness,
                height: lineThickness,
                depth: axisLen * 2
            )

            var material = gridMaterial
            if isAxisLine {
                material = xAxisMaterial
            }

            let entity = Entity()
            entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
            entity.position = SIMD3<Float>(offset, 0, 0)
            gridRoot.addChild(entity)
        }

        // Y axis (vertical) - only if showing axes
        let yAxisLen = axisLen * 0.5  // Shorter vertical axis
        let yAxisMesh = MeshResource.generateBox(
            width: lineThickness,
            height: yAxisLen,
            depth: lineThickness
        )
        let yAxisEntity = Entity()
        yAxisEntity.components.set(ModelComponent(mesh: yAxisMesh, materials: [yAxisMaterial]))
        yAxisEntity.position = SIMD3<Float>(0, yAxisLen / 2, 0)
        gridRoot.addChild(yAxisEntity)

        return gridRoot
    }
}
