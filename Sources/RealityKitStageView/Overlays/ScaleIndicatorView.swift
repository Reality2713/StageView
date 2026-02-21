import SwiftUI

/// Zoom-aware scale indicator that shows real-world distance for a fixed screen width.
/// The bar stays constant screen size while the label changes based on zoom level.
public struct ScaleIndicatorView: View {
    private let referenceDistance: Double
    private let usesReferenceAsModelExtent: Bool

    /// The fixed screen width for the scale bar (in points). Defaults to 80pt.
    let barWidth: Double

    /// Field of view of the camera (in degrees, horizontal). Defaults to ~67° (typical for RealityKit).
    let fieldOfView: Double

    public init(
        cameraDistance: Double,
        barWidth: Double = 80,
        fieldOfView: Double = 67
    ) {
        self.referenceDistance = cameraDistance
        self.usesReferenceAsModelExtent = false
        self.barWidth = barWidth
        self.fieldOfView = fieldOfView
    }

    /// Displays model extent directly (world-space), independent of camera.
    public init(
        modelExtentMeters: Double,
        barWidth: Double = 80
    ) {
        self.referenceDistance = modelExtentMeters
        self.usesReferenceAsModelExtent = true
        self.barWidth = barWidth
        self.fieldOfView = 67
    }

    /// Calculate what real-world distance (in meters) fits in our fixed bar width.
    private var realWorldDistanceForBar: Double {
        guard referenceDistance > 0, referenceDistance.isFinite else { return 0 }
        if usesReferenceAsModelExtent { return referenceDistance }
        let fovRadians = fieldOfView * .pi / 180.0
        let visibleWidthAtDistance = 2.0 * referenceDistance * tan(fovRadians / 2.0)
        let assumedScreenWidth: Double = 800.0 // Adjusted for split-viewports
        let barFraction = barWidth / assumedScreenWidth
        return visibleWidthAtDistance * barFraction
    }

    /// Choose a nice round number for the label (1, 2, 5, 10, 20, 50, 100, etc.)
    private var normalizedDistance: Double {
        let raw = realWorldDistanceForBar
        guard raw > 0, raw.isFinite else { return 0 }
        
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
        if normalizedDistance > 0 {
            scaleBar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
								.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var scaleBar: some View {
        let distance = normalizedDistance
        let width = barWidth(forDistance: distance)
        
        return VStack(spacing: 3) {
            Rectangle()
                .fill(.secondary.opacity(0.8))
                .frame(width: width, height: 1.5)
            Text(formatDistance(distance))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func barWidth(forDistance distance: Double) -> CGFloat {
        if usesReferenceAsModelExtent {
            return CGFloat(barWidth)
        }
        let raw = realWorldDistanceForBar
        guard raw > 0 else { return 0 }
        let ratio = distance / raw
        // Ensure the bar stays within a sane range (40 to 140 pts)
        return CGFloat(min(140, max(40, barWidth * ratio)))
    }
}
