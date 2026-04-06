import Foundation
import OSLog

private let tuningLogger = Logger(subsystem: "RealityKitStageView", category: "ViewportTuning")

public enum ViewportAppearance: Sendable, Equatable {
    case light
    case dark
}

struct ViewportCameraClipping: Equatable, Sendable {
    let near: Float
    let far: Float
}

enum ViewportTuning {
    /// Gantry/StageView grid contract:
    /// - Quadrant size is stable in world-space within a scale tier so the grid
    ///   remains a real scale cue without forcing one spacing across mm-, cm-,
    ///   and meter-scale assets.
    /// - Total grid radius adapts to the model's maximum world-space extent.
    /// - Metadata changes such as meters-per-unit alter the interpreted world size,
    ///   which naturally changes the number of visible quadrants without changing
    ///   the active spacing tier.
    private static let gridMajorStepMultiplier: Double = 10.0
    private static let minimumMajorQuadrantsFromCenter: Double = 6.0
    private static let gridRadiusToMaxExtentMultiplier: Double = 2.0

    static func defaultCameraDistance(
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        horizontalFOVDegrees: Float = 60
    ) -> Float {
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds)
        let halfFOV = horizontalFOVDegrees * .pi / 360.0
        let framedDistance = radiusUnits / Swift.max(tan(halfFOV), 0.001)
        let minDist = minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let result = Swift.max(
            framedDistance * 1.15,
            minDist * 2.0
        )
        tuningLogger.info("[ViewportTuning] defaultCameraDistance: maxExtent=\(sceneBounds.maxExtent) radiusUnits=\(radiusUnits) framedDist=\(framedDistance) minDist=\(minDist) metersPerUnit=\(metersPerUnit) → distance=\(result)")
        return result
    }

    static func minimumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        // Keep only a small technical floor so close inspection is limited by
        // renderer precision and clipping stability, not by scene-relative heuristics.
        metersToSceneUnits(0.0001, metersPerUnit: metersPerUnit)
    }

    static func maximumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds)
        let absoluteCeilingUnits = metersToSceneUnits(500.0, metersPerUnit: metersPerUnit)
        return Swift.max(absoluteCeilingUnits, radiusUnits * 400.0)
    }

    static func panScale(distance: Float, sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds)
        return Swift.max(distance * 0.00125, radiusUnits * 0.00075)
    }

    static func clippingRange(
        distance: Float,
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        environmentRadius: Float? = nil
    ) -> ViewportCameraClipping {
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds)
        let safeDistance = Swift.max(distance, minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit))
        let absoluteNear = metersToSceneUnits(0.0005, metersPerUnit: metersPerUnit)

        var nearClip = Swift.max(
            absoluteNear,
            Swift.min(safeDistance * 0.1, Swift.max(radiusUnits * 0.02, absoluteNear))
        )
        var farClip = Swift.max(
            safeDistance + radiusUnits * 40.0,
            radiusUnits * 120.0
        )

        let maxRatio: Float = 200_000
        if farClip / nearClip > maxRatio {
            nearClip = farClip / maxRatio
        }
        if farClip <= nearClip {
            farClip = nearClip + metersToSceneUnits(1.0, metersPerUnit: metersPerUnit)
        }

        if let envRadius = environmentRadius {
            farClip = Swift.max(farClip, envRadius * 1.05)
        }

        return ViewportCameraClipping(near: nearClip, far: farClip)
    }

    static func gridRadiusMeters(worldExtentMeters: Double) -> Double {
        let minimumRadius = majorGridStepMeters(
            forMinorStep: minorGridStepMeters(forWorldExtentMeters: worldExtentMeters)
        )
            * minimumMajorQuadrantsFromCenter
        return Swift.max(
            minimumRadius,
            worldExtentMeters * gridRadiusToMaxExtentMultiplier
        )
    }

    static func minorGridStepMeters(forGridRadius radiusMeters: Double) -> Double {
        switch radiusMeters {
        case ..<0.1:
            return 0.001
        case ..<6.0:
            return 0.01
        default:
            return 0.1
        }
    }

    static func majorGridStepMeters(forMinorStep minorStep: Double) -> Double {
        minorStep * gridMajorStepMultiplier
    }

    private static func minorGridStepMeters(forWorldExtentMeters worldExtentMeters: Double) -> Double {
        minorGridStepMeters(
            forGridRadius: Swift.max(
                worldExtentMeters * gridRadiusToMaxExtentMultiplier,
                0
            )
        )
    }

    private static func sceneRadiusUnits(sceneBounds: SceneBounds) -> Float {
        Swift.max(sceneBounds.maxExtent * 0.5, 0.0001)
    }

    private static func metersToSceneUnits(_ meters: Float, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = Float(Swift.max(metersPerUnit, 0.000_001))
        return meters / safeMetersPerUnit
    }
}
