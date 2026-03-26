import Foundation
import Testing
@testable import RealityKitStageView

struct ViewportTuningTests {
    @Test
    func defaultDistanceAndLimitsScaleWithSceneSize() {
        let tiny = SceneBounds(min: .zero, max: SIMD3<Float>(repeating: 0.05))
        let large = SceneBounds(min: .zero, max: SIMD3<Float>(repeating: 20.0))

        let tinyDistance = ViewportTuning.defaultCameraDistance(sceneBounds: tiny, metersPerUnit: 1.0)
        let largeDistance = ViewportTuning.defaultCameraDistance(sceneBounds: large, metersPerUnit: 0.001)

        #expect(tinyDistance > 0)
        #expect(largeDistance > tinyDistance)
        #expect(ViewportTuning.minimumDistance(sceneBounds: tiny, metersPerUnit: 1.0) < tinyDistance)
        #expect(ViewportTuning.maximumDistance(sceneBounds: large, metersPerUnit: 0.001) > largeDistance)
    }

    @Test
    func clippingRangeStaysOrderedAndSceneRelative() {
        let bounds = SceneBounds(min: .zero, max: SIMD3<Float>(repeating: 2.0))

        let nearClip = ViewportTuning.clippingRange(distance: 0.5, sceneBounds: bounds, metersPerUnit: 1.0)
        let farClip = ViewportTuning.clippingRange(distance: 10.0, sceneBounds: bounds, metersPerUnit: 1.0)

        #expect(nearClip.near > 0)
        #expect(nearClip.far > nearClip.near)
        #expect(farClip.far >= nearClip.far)
    }

    @Test
    func gridRadiusUsesAdaptiveExtentButFixedMajorReference() {
        let smallRadius = ViewportTuning.gridRadiusMeters(worldExtentMeters: 0.05)
        let largeRadius = ViewportTuning.gridRadiusMeters(worldExtentMeters: 20.0)

        #expect(smallRadius >= 0.25)
        #expect(smallRadius < 5.0)
        #expect(largeRadius > smallRadius)
        #expect(ViewportTuning.minorGridStepMeters(forGridRadius: 4.0) == 0.1)
        #expect(ViewportTuning.minorGridStepMeters(forGridRadius: 40.0) == 0.5)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.1) == 1.0)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.5) == 5.0)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.01) == 0.1)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 1.0) == 10.0)
    }

    @Test
    func realityKitExposureAppliesBaselineCalibration() {
        #expect(RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 0.0) == -1.0)
        #expect(RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 1.0) == 0.0)
        #expect(RealityKitConfiguration.hydraLinearExposureGain(forEV: 1.0) == 1.0)
    }

    @Test
    func realityKitExposureIsMonotonicAndCappedAtTopEnd() {
        let midpoint = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 1.5)
        let high = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 3.0)
        let maxed = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 10.0)

        #expect(midpoint < high)
        #expect(high <= 1.8)
        #expect(maxed == 1.8)
        #expect(RealityKitConfiguration.hydraLinearExposureGain(forEV: 10.0) <= Float(pow(2.0, 1.8)))
    }
}
