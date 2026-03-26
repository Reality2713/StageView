import SwiftUI

private struct ScaleIndicatorMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        #endif
    }
}

struct DynamicScaleReference: Equatable {
    let meters: Double
    let label: String

    static func compute(
        referenceDepthMeters: Double,
        horizontalFOVDegrees: Double,
        viewportWidthPoints: Double,
        barWidthPoints: Double
    ) -> DynamicScaleReference? {
        guard referenceDepthMeters.isFinite, referenceDepthMeters > 0 else { return nil }
        guard horizontalFOVDegrees.isFinite, horizontalFOVDegrees > 1, horizontalFOVDegrees < 179 else { return nil }
        guard viewportWidthPoints.isFinite, viewportWidthPoints > 1 else { return nil }
        guard barWidthPoints.isFinite, barWidthPoints > 1 else { return nil }

        let fovRadians = horizontalFOVDegrees * .pi / 180.0
        let visibleWidthMeters = 2.0 * referenceDepthMeters * tan(fovRadians / 2.0)
        guard visibleWidthMeters.isFinite, visibleWidthMeters > 0 else { return nil }

        let rawMeters = visibleWidthMeters * (barWidthPoints / viewportWidthPoints)
        guard rawMeters.isFinite, rawMeters > 0 else { return nil }

        let snappedMeters = snapToNiceMetricStep(rawMeters)
        return .init(meters: snappedMeters, label: formatMetric(snappedMeters))
    }

    private static func snapToNiceMetricStep(_ value: Double) -> Double {
        let clamped = min(1_000_000.0, max(0.000_001, value))
        let exponent = floor(log10(clamped))
        let magnitude = pow(10.0, exponent)
        let normalized = clamped / magnitude
        let candidates: [Double] = [1, 2, 5, 10]
        let nearest = candidates.min(by: { (lhs: Double, rhs: Double) -> Bool in
            Swift.abs(lhs - normalized) < Swift.abs(rhs - normalized)
        }) ?? 1.0
        return nearest * magnitude
    }

    private static func formatMetric(_ meters: Double) -> String {
        let value: Double
        let unit: String
        if meters < 0.01 {
            value = meters * 1000
            unit = "mm"
        } else if meters < 1.0 {
            value = meters * 100
            unit = "cm"
        } else if meters < 1000 {
            value = meters
            unit = "m"
        } else {
            value = meters / 1000
            unit = "km"
        }
        return "\(compact(value))\(unit)"
    }

    private static func compact(_ value: Double) -> String {
        if value >= 100 || Swift.abs(value.rounded() - value) < 0.001 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

/// Maps-style dynamic scale indicator.
public struct ScaleIndicatorView: View {
    let referenceDepthMeters: Double
    let viewportWidthPoints: Double
    let barWidth: Double
    let horizontalFOVDegrees: Double

    public init(
        referenceDepthMeters: Double,
        viewportWidthPoints: Double,
        barWidth: Double = 88,
        horizontalFOVDegrees: Double = 60
    ) {
        self.referenceDepthMeters = referenceDepthMeters
        self.viewportWidthPoints = viewportWidthPoints
        self.barWidth = barWidth
        self.horizontalFOVDegrees = horizontalFOVDegrees
    }

    public var body: some View {
        if let scale = DynamicScaleReference.compute(
            referenceDepthMeters: referenceDepthMeters,
            horizontalFOVDegrees: horizontalFOVDegrees,
            viewportWidthPoints: viewportWidthPoints,
            barWidthPoints: barWidth
        ) {
            VStack(spacing: 3) {
                Rectangle()
                    .fill(.secondary.opacity(0.8))
                    .frame(width: barWidth, height: 1.5)
                Text(scale.label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(ScaleIndicatorMaterialModifier())
        }
    }
}
