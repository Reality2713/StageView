#if !os(visionOS)
import RealityKit
import SwiftUI
import Testing
@testable import RealityKitStageView

@MainActor
struct PostProcessOutlineEffectTests {
    @Test
    func copiesShareSettings() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) else { return }
        let original = PostProcessOutlineEffect(color: .cyan, radius: 2, prefersChildMeshes: false)
        var copy = original
        copy.radius = 5
        copy.prefersChildMeshes = true
        copy.color = .red
        #expect(original.radius == 5)
        #expect(original.prefersChildMeshes)
        #expect(original.color == .red)
    }

    @Test(arguments: [false, true])
    func prefersChildMeshesRoundTrips(_ prefers: Bool) {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) else { return }
        var effect = PostProcessOutlineEffect(prefersChildMeshes: prefers)
        #expect(effect.prefersChildMeshes == prefers)
        effect.prefersChildMeshes = !prefers
        #expect(effect.prefersChildMeshes == !prefers)
    }

    @Test
    func defaultsMatchPreviousStageView() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) else { return }
        let effect = PostProcessOutlineEffect()
        #expect(effect.color == .cyan)
        #expect(effect.radius == 2)
        #expect(!effect.prefersChildMeshes)
    }
}
#endif
