import SwiftUI

/// Auto-switching scale indicator that shows "1m | 5m" reference based on scene size.
public struct ScaleIndicatorView: View {
    let sceneBounds: SceneBounds
    let metersPerUnit: Double

    public init(sceneBounds: SceneBounds, metersPerUnit: Double) {
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
    }

    /// Auto-select appropriate scale unit based on scene size
    private var autoUnit: GridConfiguration.ScaleUnit {
        let sizeInMeters = Double(sceneBounds.maxExtent) * metersPerUnit
        if sizeInMeters < 1.0 {
            return .centimeters
        } else if sizeInMeters > 1000.0 {
            return .kilometers
        } else {
            return .meters
        }
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
        VStack(spacing: 2) {
            Rectangle()
                .frame(width: CGFloat(multiplier) * 20, height: 2)
                .foregroundStyle(.secondary)
            Text("\(multiplier)\(autoUnit.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
