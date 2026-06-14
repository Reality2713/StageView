import SwiftUI
import Testing
@testable import RealityKitStageView

@Suite
struct RealityKitConfigurationAdoptionTests {
    @Test
    func defaultsArePreserved() {
        let config = RealityKitConfiguration()
        #expect(config.interactionMode == .camera)
        #expect(config.source == .url)
        #expect(config.appearance == nil)
        // Existing defaults remain unchanged (additive change).
        #expect(config.showGrid == true)
        #expect(config.showEnvironmentBackground == true)
    }

    @Test
    func injectedEntitySourceIsExpressible() {
        var config = RealityKitConfiguration()
        config.source = .injectedEntity
        config.interactionMode = .entityDrag
        #expect(config.source == .injectedEntity)
        #expect(config.interactionMode == .entityDrag)
    }

    @Test
    func appearanceKnobThemesBackgroundAndGridDeterministically() {
        // The friction-#9 one-liner: a forced .dark appearance must theme the
        // viewport regardless of the host color scheme, for both background and
        // grid, with no skybox/showEnvironmentBackground knowledge required.
        let dark = StageViewAppearance.dark
        let resolvedFromLightHost = dark.resolvedAppearance(for: .light)
        let resolvedFromDarkHost = dark.resolvedAppearance(for: .dark)

        // Same dark result regardless of the embedding color scheme.
        #expect(resolvedFromLightHost == resolvedFromDarkHost)
        #expect(resolvedFromLightHost.viewportAppearance == .dark)
        #expect(resolvedFromLightHost.backgroundColor == SIMD4<Float>(0.18, 0.18, 0.18, 1.0))
        // Grid colors are themed too (dark palette differs from light palette).
        let light = StageViewAppearance.light.resolvedAppearance(for: .light)
        #expect(resolvedFromLightHost.gridMinorColor != light.gridMinorColor)
    }

    @Test
    func configurationAppearanceIsCarried() {
        var config = RealityKitConfiguration()
        config.appearance = .dark
        #expect(config.appearance == .dark)
    }
}
