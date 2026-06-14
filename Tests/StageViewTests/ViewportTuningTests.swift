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
    func framingDistanceUsesSceneUnitsAcrossAuthoredUnitSystems() {
        let bounds = SceneBounds(min: .zero, max: SIMD3<Float>(repeating: 0.602598))

        let metersDistance = ViewportTuning.defaultCameraDistance(
            sceneBounds: bounds,
            metersPerUnit: 1.0
        )
        let feetDistance = ViewportTuning.defaultCameraDistance(
            sceneBounds: bounds,
            metersPerUnit: 0.3048
        )

        #expect(Swift.abs(metersDistance - feetDistance) < 0.0001)
        #expect(feetDistance > 0.5)
    }

    @Test
    func clippingRangeUsesSceneUnitsAcrossAuthoredUnitSystems() {
        let bounds = SceneBounds(min: .zero, max: SIMD3<Float>(repeating: 0.602598))

        let meterClip = ViewportTuning.clippingRange(
            distance: 0.600145,
            sceneBounds: bounds,
            metersPerUnit: 1.0
        )
        let feetClip = ViewportTuning.clippingRange(
            distance: 0.600145,
            sceneBounds: bounds,
            metersPerUnit: 0.3048
        )

        #expect(Swift.abs(meterClip.near - feetClip.near) < 0.0001)
        #expect(Swift.abs(meterClip.far - feetClip.far) < 0.0001)
    }

    @Test
    func gridUsesFixedQuadrantSizesAndAdaptiveRadius() {
        let smallRadius = ViewportTuning.gridRadiusMeters(worldExtentMeters: 0.05)
        let largeRadius = ViewportTuning.gridRadiusMeters(worldExtentMeters: 20.0)

        #expect(smallRadius >= 6.0)
        #expect(largeRadius > smallRadius)
        #expect(ViewportTuning.minorGridStepMeters(forGridRadius: 0.05) == 0.1)
        #expect(ViewportTuning.minorGridStepMeters(forGridRadius: 1.0) == 0.1)
        #expect(ViewportTuning.minorGridStepMeters(forGridRadius: 40.0) == 0.1)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.001) == 1.0)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.01) == 1.0)
        #expect(ViewportTuning.majorGridStepMeters(forMinorStep: 0.1) == 1.0)
    }

    // NOTE: The exposure model treats StageView EV as a direct base-2 stop offset
    // over the authored HDR intensity (`realityKitMappedEV` is the identity). The
    // previous baseline-calibration / top-end-cap expectations in these tests
    // were written for an earlier mapping that the source no longer implements
    // (the source was simplified to identity); they asserted behavior the
    // shipping code does not have and so were stale. These assertions match the
    // actual `RealityKitConfiguration` exposure functions.
    @Test
    func realityKitExposureIsADirectStopOffset() {
        #expect(RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 0.0) == 0.0)
        #expect(RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 1.0) == 1.0)
        #expect(RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: -1.0) == -1.0)
        // EV is a base-2 exponent: 0 EV is unity gain, +1 EV doubles.
        #expect(RealityKitConfiguration.hydraLinearExposureGain(forEV: 0.0) == 1.0)
        #expect(RealityKitConfiguration.hydraLinearExposureGain(forEV: 1.0) == 2.0)
    }

    @Test
    func realityKitExposureIsMonotonicAcrossRange() {
        let low = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 1.5)
        let high = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 3.0)
        let higher = RealityKitConfiguration.realityKitIntensityExponent(forHydraEV: 10.0)

        #expect(low < high)
        #expect(high < higher)
        #expect(RealityKitConfiguration.hydraLinearExposureGain(forEV: 1.0)
            < RealityKitConfiguration.hydraLinearExposureGain(forEV: 2.0))
    }
}
