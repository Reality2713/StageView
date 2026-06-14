import Foundation
import RealityKit
import Testing
import simd
@testable import RealityKitStageView

@Suite
@MainActor
struct RealityKitProviderEntityDragTests {
    // MARK: - Injected-entity source flag (friction #2/#3)

    @Test
    func setModelMarksProviderExternallyDriven() {
        let provider = RealityKitProvider()
        #expect(provider.isExternallyDriven == false)
        provider.setModel(makeTree(), metersPerUnit: 1.0, isZUp: false)
        #expect(provider.isExternallyDriven == true)
        #expect(provider.isLoaded == true)
    }

    @Test
    func teardownClearsExternallyDriven() {
        let provider = RealityKitProvider()
        provider.setModel(makeTree(), metersPerUnit: 1.0, isZUp: false)
        provider.teardown()
        #expect(provider.isExternallyDriven == false)
        #expect(provider.isLoaded == false)
    }

    // MARK: - Host-free bounds derivation (friction #5)

    @Test
    func derivesFrameableBoundsFromInjectedGeometryWhenNoneSupplied() {
        let provider = RealityKitProvider()
        provider.setModel(makeBoxTree(), metersPerUnit: 1.0, isZUp: false)
        // No setExternalSceneBounds call: bounds must still be frameable.
        #expect(provider.sceneBounds.isFrameable)
        #expect(provider.sceneBounds.maxExtent > 0)
    }

    @Test
    func structuralOnlySceneWithoutGeometryDoesNotFabricateBounds() {
        let provider = RealityKitProvider()
        // Structural-only tree (no ModelComponent) → no geometry to derive from.
        // Honest behavior: bounds are not frameable until the host supplies them
        // (or geometry is present). The provider no longer logs an error/clears
        // when geometry IS present (see the geometry test above).
        provider.setModel(makeTree(), metersPerUnit: 1.0, isZUp: false)
        #expect(provider.sceneBounds.isFrameable == false)

        // The host can still supply authored bounds for a structural scene.
        let authored = SceneBounds(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        provider.setExternalSceneBounds(authored)
        #expect(provider.sceneBounds == authored)
    }

    @Test
    func externalBoundsStillOverrideDerivedBounds() {
        let provider = RealityKitProvider()
        let authored = SceneBounds(min: SIMD3<Float>(-2, -2, -2), max: SIMD3<Float>(2, 2, 2))
        provider.setExternalSceneBounds(authored)
        provider.setModel(makeBoxTree(), metersPerUnit: 1.0, isZUp: false)
        #expect(provider.sceneBounds == authored)
    }

    // MARK: - setModel(rootNode:) overload (friction #4)

    @Test
    func setModelRootNodeMapsTheRootItselfAsFirstPrim() {
        let provider = RealityKitProvider()
        let world = Entity()
        world.name = "World"
        let child = Entity()
        child.name = "Child"
        world.addChild(child)

        provider.setModel(rootNode: world, metersPerUnit: 1.0, isZUp: false)

        // The passed root is mapped as the first prim (selectable), not discarded.
        #expect(provider.entity(for: "/World")?.name == "World")
        #expect(provider.entity(for: "/World/Child")?.name == "Child")
    }

    @Test
    func plainSetModelTreatsArgumentAsAnonymousWrapper() {
        let provider = RealityKitProvider()
        let world = Entity()
        world.name = "World"
        let child = Entity()
        child.name = "Child"
        world.addChild(child)

        // Plain setModel maps children of the argument, not the argument itself.
        provider.setModel(world, metersPerUnit: 1.0, isZUp: false)
        #expect(provider.entity(for: "/Child")?.name == "Child")
    }

    // MARK: - Scene-space entity drag (TOP PRIORITY)

    @Test
    func entityDragReportsSceneSpaceSamplesAndDoesNotMoveEntity() {
        let provider = RealityKitProvider()
        let model = makeBoxTreeNamed("/World/Box", leafName: "Box", parentName: "World")
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)
        provider.setSelection("/World/Box")

        var samples: [SceneSpaceDragSample] = []
        provider.setEntityDragHandler { samples.append($0) }

        let boxBefore = provider.entity(for: "/World/Box")?.transform.translation

        #expect(provider.beginEntityDrag() == true)
        #expect(provider.isEntityDragging == true)
        provider.updateEntityDrag(
            screenDelta: SIMD2<Double>(100, 0),
            viewLocation: SIMD2<Double>(500, 300),
            viewSize: SIMD2<Double>(800, 600)
        )
        provider.updateEntityDrag(
            screenDelta: SIMD2<Double>(100, 0),
            viewLocation: SIMD2<Double>(600, 300),
            viewSize: SIMD2<Double>(800, 600)
        )
        provider.endEntityDrag()
        #expect(provider.isEntityDragging == false)

        // Phases: began, changed, changed, ended.
        #expect(samples.count == 4)
        #expect(samples.first?.phase == .began)
        #expect(samples[1].phase == .changed)
        #expect(samples.last?.phase == .ended)
        #expect(samples.allSatisfy { $0.primPath == "/World/Box" })

        // Incremental deltas accumulate into totalDelta. Default camera looks
        // down -Z (identity), so a rightward drag moves +X.
        let perStep = 100.0 * Double(provider.cameraDistance)
            * SceneSpaceDragMath.sceneUnitsPerPointAtUnitDistance
        #expect(abs(samples[1].delta.x - perStep) < 1e-9)
        #expect(abs(samples[2].totalDelta.x - perStep * 2) < 1e-9)

        // StageView must NOT have moved the entity itself.
        let boxAfter = provider.entity(for: "/World/Box")?.transform.translation
        #expect(boxBefore == boxAfter)
    }

    @Test
    func beginEntityDragFailsWithoutSelection() {
        let provider = RealityKitProvider()
        provider.setModel(makeBoxTree(), metersPerUnit: 1.0, isZUp: false)
        // No selection set.
        #expect(provider.beginEntityDrag() == false)
        #expect(provider.isEntityDragging == false)
    }

    @Test
    func entityDragPublishesObservableSampleAndGeneration() {
        let provider = RealityKitProvider()
        let model = makeBoxTreeNamed("/World/Box", leafName: "Box", parentName: "World")
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)
        provider.setSelection("/World/Box")

        #expect(provider.lastSceneDragSample == nil)
        let gen0 = provider.sceneDragGeneration
        provider.beginEntityDrag()
        #expect(provider.lastSceneDragSample?.phase == .began)
        #expect(provider.sceneDragGeneration == gen0 + 1)
        provider.endEntityDrag()
        #expect(provider.lastSceneDragSample?.phase == .ended)
        #expect(provider.sceneDragGeneration == gen0 + 2)
    }

    // MARK: - Builders

    private func makeTree() -> Entity {
        let root = Entity()
        root.name = ""
        let node = Entity()
        node.name = "Node"
        root.addChild(node)
        return root
    }

    private func makeBoxTree() -> Entity {
        makeBoxTreeNamed("/Box", leafName: "Box", parentName: nil)
    }

    private func makeBoxTreeNamed(_ path: String, leafName: String, parentName: String?) -> Entity {
        let root = Entity()
        root.name = ""

        let box = ModelEntity(
            mesh: .generateBox(size: 1),
            materials: [SimpleMaterial()]
        )
        box.name = leafName
        box.transform.translation = SIMD3<Float>(0, 0, 0)

        if let parentName {
            let parent = Entity()
            parent.name = parentName
            parent.addChild(box)
            root.addChild(parent)
        } else {
            root.addChild(box)
        }
        return root
    }
}
