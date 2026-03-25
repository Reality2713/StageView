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

    @Test
    func prefersSemanticSiblingForGenericMergedPickPath() {
        let provider = RealityKitProvider()
        let model = makeMergedPickModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        let merged = model.children.first?.children.first(where: { $0.name == "merged_1" })
        let resolved = merged.flatMap { provider.preferredPickPrimPath(from: $0) }

        #expect(resolved == "/RootNode/M_Forklift_C01")
    }

    @Test
    func keepsSpecificPickPathWhenEntityIsNotGeneric() {
        let provider = RealityKitProvider()
        let model = makeMergedPickModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        let target = model.children.first?.children.first(where: { $0.name == "M_Forklift_C01_Blue" })
        let resolved = target.flatMap { provider.preferredPickPrimPath(from: $0) }

        #expect(resolved == "/RootNode/M_Forklift_C01_Blue")
    }

    @Test
    func usesConsumerPickOverrideBeforeBuiltInFallback() {
        let provider = RealityKitProvider()
        let model = makeMergedPickModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)
        provider.setPickPathOverrides([
            "/RootNode/merged_1": "/RootNode/M_Forklift_C01_Glass"
        ])

        let merged = model.children.first?.children.first(where: { $0.name == "merged_1" })
        let resolved = merged.flatMap { provider.preferredPickPrimPath(from: $0) }

        #expect(resolved == "/RootNode/M_Forklift_C01_Glass")
    }

    @Test
    func usesConsumerResolverBeforeBuiltInFallback() {
        let provider = RealityKitProvider()
        let model = makeMergedPickModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)
        provider.setPickPathResolver { directPath, _, _ in
            if directPath == "/RootNode/merged_1" {
                return "/RootNode/M_Forklift_C01_Decals"
            }
            return nil
        }

        let merged = model.children.first?.children.first(where: { $0.name == "merged_1" })
        let resolved = merged.flatMap { provider.preferredPickPrimPath(from: $0) }

        #expect(resolved == "/RootNode/M_Forklift_C01_Decals")
    }

    @Test
    func prefersSpecificPathFromOrderedHitList() {
        let provider = RealityKitProvider()
        let model = makeMergedPickModelTree()
        provider.setModel(model, metersPerUnit: 1.0, isZUp: false)

        let merged = model.children.first?.children.first(where: { $0.name == "merged_1" })
        let specific = model.children.first?.children.first(where: { $0.name == "M_Forklift_C01_Glass" })
        let resolved = provider.preferredPickPrimPath(from: [merged, specific].compactMap { $0 })

        #expect(resolved == "/RootNode/M_Forklift_C01_Glass")
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

    private func makeMergedPickModelTree() -> Entity {
        let root = Entity()
        root.name = ""

        let rootNode = Entity()
        rootNode.name = "RootNode"

        let assembly = Entity()
        assembly.name = "M_Forklift_C01"

        let blue = Entity()
        blue.name = "M_Forklift_C01_Blue"

        let decals = Entity()
        decals.name = "M_Forklift_C01_Decals"

        let glass = Entity()
        glass.name = "M_Forklift_C01_Glass"

        let merged = Entity()
        merged.name = "merged_1"

        rootNode.addChild(assembly)
        rootNode.addChild(blue)
        rootNode.addChild(decals)
        rootNode.addChild(glass)
        rootNode.addChild(merged)
        root.addChild(rootNode)
        return root
    }
}
