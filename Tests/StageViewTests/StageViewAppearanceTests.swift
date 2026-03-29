import SwiftUI
import Testing
@testable import RealityKitStageView

struct StageViewAppearanceTests {
    @Test
    func automaticTracksHostAppearance() {
        let appearance = StageViewAppearance.automatic

        let light = appearance.resolvedAppearance(for: .light)
        let dark = appearance.resolvedAppearance(for: .dark)

        #expect(light.viewportAppearance == .light)
        #expect(dark.viewportAppearance == .dark)
        #expect(light.backgroundColor == SIMD4<Float>(0.93, 0.94, 0.96, 1.0))
        #expect(dark.backgroundColor == SIMD4<Float>(0.18, 0.18, 0.18, 1.0))
    }

    @Test
    func explicitModesIgnoreHostAppearance() {
        let lightAppearance = StageViewAppearance.light
        let darkAppearance = StageViewAppearance.dark

        #expect(lightAppearance.resolvedAppearance(for: .dark).viewportAppearance == .light)
        #expect(darkAppearance.resolvedAppearance(for: .light).viewportAppearance == .dark)
    }

    @Test
    func customBackgroundPaletteResolvesPerAppearance() {
        let appearance = StageViewAppearance.custom(
            StageViewAppearanceOverrides(
                background: .palette(
                    light: SIMD4<Float>(0.8, 0.81, 0.82, 1.0),
                    dark: SIMD4<Float>(0.1, 0.11, 0.12, 1.0)
                )
            )
        )

        #expect(appearance.resolvedAppearance(for: .light).backgroundColor == SIMD4<Float>(0.8, 0.81, 0.82, 1.0))
        #expect(appearance.resolvedAppearance(for: .dark).backgroundColor == SIMD4<Float>(0.1, 0.11, 0.12, 1.0))
    }

    @Test
    func customBackgroundColorBypassesAutomaticPalette() {
        let appearance = StageViewAppearance.custom(
            StageViewAppearanceOverrides(
                background: .color(SIMD4<Float>(0.2, 0.3, 0.4, 0.5))
            )
        )

        #expect(appearance.resolvedAppearance(for: .light).backgroundColor == SIMD4<Float>(0.2, 0.3, 0.4, 0.5))
        #expect(appearance.resolvedAppearance(for: .dark).backgroundColor == SIMD4<Float>(0.2, 0.3, 0.4, 0.5))
    }

    @Test
    func customGridPaletteOverridesBuiltInDefaults() {
        let appearance = StageViewAppearance.custom(
            StageViewAppearanceOverrides(
                grid: StageViewGridStyle(
                    minorColor: .palette(
                        light: SIMD3<Float>(0.7, 0.7, 0.7),
                        dark: SIMD3<Float>(0.2, 0.2, 0.2)
                    ),
                    majorColor: .color(SIMD3<Float>(0.9, 0.8, 0.7))
                )
            )
        )

        let light = appearance.resolvedAppearance(for: .light)
        let dark = appearance.resolvedAppearance(for: .dark)

        #expect(light.gridMinorColor == SIMD3<Float>(0.7, 0.7, 0.7))
        #expect(dark.gridMinorColor == SIMD3<Float>(0.2, 0.2, 0.2))
        #expect(light.gridMajorColor == SIMD3<Float>(0.9, 0.8, 0.7))
        #expect(dark.gridMajorColor == SIMD3<Float>(0.9, 0.8, 0.7))
    }

}
