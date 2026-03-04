import Testing
@testable import RealityKitStageView
import RealityKit

@Suite
@MainActor
struct RealityKitProviderSelectionResolutionTests {
    @Test
    func resolvesExactPath() {
        let provider = RealityKitProvider()
        let model = makeSimpleModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        let resolved = provider.selectionEntity(for: "/Robot/Body")
        #expect(resolved?.name == "Body")
    }

    @Test
    func resolvesByDroppingLeadingSegment() {
        let provider = RealityKitProvider()
        let model = makeSimpleModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        // Hydra can include an extra stage root segment not present in RK mapping.
        let resolved = provider.selectionEntity(for: "/Root/Robot/Body")
        #expect(resolved?.name == "Body")
    }

    @Test
    func resolvesToNearestAncestorWhenLeafIsMissing() {
        let provider = RealityKitProvider()
        let model = makeSimpleModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        let resolved = provider.selectionEntity(for: "/Robot/Body/UnknownLeaf")
        #expect(resolved?.name == "Body")
    }

    private func makeSimpleModelTree() -> Entity {
        let root = Entity()
        root.name = ""

        let robot = Entity()
        robot.name = "Robot"

        let body = Entity()
        body.name = "Body"

        robot.addChild(body)
        root.addChild(robot)
        return root
    }
}
