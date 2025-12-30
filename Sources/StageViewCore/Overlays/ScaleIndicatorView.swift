import SwiftUI

/// Zoom-aware scale indicator that shows real-world distance for a fixed screen width.
/// The bar stays constant screen size while the label changes based on zoom level.
public struct ScaleIndicatorView: View {
    /// Distance from camera to target (in meters). Used to calculate scale.
    let cameraDistance: Double

    /// The fixed screen width for the scale bar (in points). Defaults to 80pt.
    let barWidth: Double

    /// Field of view of the camera (in degrees, horizontal). Defaults to ~67° (typical for RealityKit).
    let fieldOfView: Double

    public init(
        cameraDistance: Double,
        barWidth: Double = 80,
        fieldOfView: Double = 67
    ) {
        self.cameraDistance = cameraDistance
        self.barWidth = barWidth
        self.fieldOfView = fieldOfView
    }

    /// Calculate what real-world distance (in meters) fits in our fixed bar width.
    private var realWorldDistanceForBar: Double {
        let fovRadians = fieldOfView * .pi / 180.0
        let visibleWidthAtDistance = 2.0 * cameraDistance * tan(fovRadians / 2.0)
        let assumedScreenWidth: Double = 1200.0
        let barFraction = barWidth / assumedScreenWidth
        return visibleWidthAtDistance * barFraction
    }

    /// Choose a nice round number for the label (1, 2, 5, 10, 20, 50, 100, etc.)
    private var normalizedDistance: Double {
        let raw = realWorldDistanceForBar
        let magnitude = pow(10.0, floor(log10(raw)))
        let normalized = raw / magnitude

        let niceNormalized: Double
        if normalized < 1.5 { niceNormalized = 1.0 }
        else if normalized < 3.5 { niceNormalized = 2.0 }
        else if normalized < 7.5 { niceNormalized = 5.0 }
        else { niceNormalized = 10.0 }

        return niceNormalized * magnitude
    }

    /// Format distance with appropriate unit
    private func formatDistance(_ meters: Double) -> String {
        let value: Double
        let unit: String

        if meters < 0.01 {
            value = meters * 1000
            unit = "mm"
        } else if meters < 1.0 {
            value = meters * 100
            unit = "cm"
        } else if meters >= 1000.0 {
            value = meters / 1000
            unit = "km"
        } else {
            value = meters
            unit = "m"
        }

        return String(format: "%g%@", value, unit)
    }

    /// Calculate the visual bar width for each segment
    private func barWidth(forMultiplier multiplier: Int) -> CGFloat {
        let targetDistance = normalizedDistance * Double(multiplier)
        let ratio = targetDistance / realWorldDistanceForBar
        return CGFloat(barWidth * ratio)
    }

    public var body: some View {
        HStack(spacing: 8) {
            scaleBar(multiplier: 1)
            scaleBar(multiplier: 5)
        }
        .padding(8)
       	.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func scaleBar(multiplier: Int) -> some View {
        let distance = normalizedDistance * Double(multiplier)
        return VStack(spacing: 2) {
            Rectangle()
                .frame(width: barWidth(forMultiplier: multiplier), height: 2)
                .foregroundStyle(.secondary)
            Text(formatDistance(distance))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
