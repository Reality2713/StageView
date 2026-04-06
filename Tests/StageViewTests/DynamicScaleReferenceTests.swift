import Testing
@testable import StageViewOverlay

struct DynamicScaleReferenceTests {
    @Test
    func computeRejectsInvalidInputs() {
        #expect(DynamicScaleReference.compute(referenceDepthMeters: 0, horizontalFOVDegrees: 60, viewportWidthPoints: 800, barWidthPoints: 88) == nil)
        #expect(DynamicScaleReference.compute(referenceDepthMeters: 1, horizontalFOVDegrees: 0, viewportWidthPoints: 800, barWidthPoints: 88) == nil)
        #expect(DynamicScaleReference.compute(referenceDepthMeters: 1, horizontalFOVDegrees: 60, viewportWidthPoints: 0, barWidthPoints: 88) == nil)
    }

    @Test
    func metricUnitsAutoSwitch() {
        let mm = DynamicScaleReference.compute(referenceDepthMeters: 0.005, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)
        #expect(mm?.label.hasSuffix("mm") == true)

        let cm = DynamicScaleReference.compute(referenceDepthMeters: 0.1, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)
        #expect(cm?.label.hasSuffix("cm") == true)

        let meters = DynamicScaleReference.compute(referenceDepthMeters: 10, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)
        #expect(meters?.label.hasSuffix("m") == true)

        let km = DynamicScaleReference.compute(referenceDepthMeters: 20_000, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)
        #expect(km?.label.hasSuffix("km") == true)
    }

    @Test
    func displayedMetersIncreaseWithDepth() {
        let near = DynamicScaleReference.compute(referenceDepthMeters: 1, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)
        let far = DynamicScaleReference.compute(referenceDepthMeters: 100, horizontalFOVDegrees: 60, viewportWidthPoints: 880, barWidthPoints: 88)

        #expect(near != nil)
        #expect(far != nil)
        #expect((far?.meters ?? 0) > (near?.meters ?? .greatestFiniteMagnitude))
    }

    @Test
    func renderedBarMatchesReportedMeters() {
        let scale = DynamicScaleReference.compute(
            referenceDepthMeters: 3.75,
            horizontalFOVDegrees: 60,
            viewportWidthPoints: 844,
            barWidthPoints: 88
        )

        #expect(scale != nil)

        let visibleWidthMeters = 2.0 * 3.75 * tan(60.0 * .pi / 360.0)
        let metersPerPoint = visibleWidthMeters / 844.0
        let representedMeters = (scale?.barWidthPoints ?? 0) * metersPerPoint

        #expect(Swift.abs(representedMeters - (scale?.meters ?? .greatestFiniteMagnitude)) < 0.000_001)
    }

    @Test
    func renderedBarStaysInReadableRange() {
        let scale = DynamicScaleReference.compute(
            referenceDepthMeters: 25,
            horizontalFOVDegrees: 60,
            viewportWidthPoints: 1024,
            barWidthPoints: 88
        )

        #expect(scale != nil)
        #expect((scale?.barWidthPoints ?? 0) >= 56)
        #expect((scale?.barWidthPoints ?? .greatestFiniteMagnitude) <= 132)
    }

    @Test
    func framedCentimeterScaleDoesNotCollapseToMillimeters() {
        let scale = DynamicScaleReference.compute(
            referenceDepthMeters: 0.323596,
            horizontalFOVDegrees: 60,
            viewportWidthPoints: 390,
            barWidthPoints: 88
        )

        #expect(scale != nil)
        #expect(scale?.label == "10cm")
    }
}
