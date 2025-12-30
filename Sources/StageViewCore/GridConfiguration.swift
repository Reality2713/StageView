import Foundation

public struct GridConfiguration: Equatable, Sendable {
    public var isVisible: Bool = true
    public var showAxes: Bool = true
    public var metersPerUnit: Double = 1.0      // From USD file
    public var worldExtent: Double = 10.0       // Scene size for grid extent calc

    // Scale indicator
    public var scaleIndicatorUnit: ScaleUnit = .meters

    public enum ScaleUnit: String, CaseIterable, Sendable {
        case centimeters = "cm"
        case meters = "m"
        case kilometers = "km"

        public var metersValue: Double {
            switch self {
            case .centimeters: return 0.01
            case .meters: return 1.0
            case .kilometers: return 1000.0
            }
        }
    }

    public init() {}
}
