import Foundation
@testable import RealityKitStageView
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
}
