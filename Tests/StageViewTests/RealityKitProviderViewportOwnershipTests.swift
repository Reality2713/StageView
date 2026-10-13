import Foundation
@testable import RealityKitStageView
import RealityKit
import SelectionEffects
import Testing

@Suite
@MainActor
struct RealityKitProviderViewportOwnershipTests {
    @Test
    func teardownRequiresActiveViewportOwnership() {
        let provider = RealityKitProvider()
        let staleViewportID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let activeViewportID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        provider.activateViewport(activeViewportID)

        #expect(provider.isActiveViewport(activeViewportID))
        #expect(!provider.isActiveViewport(staleViewportID))

        provider.teardown(viewportID: staleViewportID)

        #expect(provider.isActiveViewport(activeViewportID))

        provider.deactivateViewport(staleViewportID)

        #expect(provider.isActiveViewport(activeViewportID))

        provider.deactivateViewport(activeViewportID)

        #expect(!provider.isActiveViewport(activeViewportID))
    }

    @Test
    func postProcessOutlineHasOneOwnerPerProvider() {
        let provider = RealityKitProvider()
        let first = Entity(), second = Entity()

        provider.setPostProcessOutline(SelectionEffectComponent(), on: first)
        provider.setPostProcessOutline(SelectionEffectComponent(), on: second)
        #expect(!first.components.has(SelectionEffectComponent.self))
        #expect(second.components.has(SelectionEffectComponent.self))

        provider.clearPostProcessOutline()
        #expect(!second.components.has(SelectionEffectComponent.self))
    }

    @Test
    func teardownClearsTheOutlineAndAdvancesTheSelectionGeneration() {
        let provider = RealityKitProvider()
        let entity = Entity()
        provider.setSelection("/World/Cube")
        provider.setPostProcessOutline(SelectionEffectComponent(), on: entity)
        let generation = provider.selectionGeneration

        provider.teardown()

        #expect(!entity.components.has(SelectionEffectComponent.self))
        #expect(provider.selectedPrimPath == nil)
        #expect(provider.selectionGeneration != generation)
    }
}
