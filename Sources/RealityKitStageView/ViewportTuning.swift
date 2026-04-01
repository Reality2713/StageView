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
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds)
        // The absolute floor should be 2mm in world space, converted back to scene units.
        let absoluteFloorUnits = metersToSceneUnits(0.002, metersPerUnit: metersPerUnit)
        return Swift.max(absoluteFloorUnits, radiusUnits * 0.12)
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
        // Keep a generous floor plane even for tiny assets so depth cues and
        // fog remain legible at normal editing camera distances without
        // forcing millimeter-scale assets onto a centimeter-scale grid.
        Swift.max(0.03, worldExtentMeters * 15.0)
    }

    static func minorGridStepMeters(forGridRadius radiusMeters: Double) -> Double {
        switch radiusMeters {
        case ..<0.08:
            return 0.001 // 1mm grid for tiny assets
        case ..<0.5:
            return 0.01 // 1cm grid for tiny assets
        case ..<10:
            return 0.1
        case ..<30:
            return 0.25
        case ..<80:
            return 0.5
        default:
            return 1.0
        }
    }

    static func majorGridStepMeters(forMinorStep minorStep: Double) -> Double {
        minorStep * 10.0
    }

    private static func sceneRadiusUnits(sceneBounds: SceneBounds) -> Float {
        Swift.max(sceneBounds.maxExtent * 0.5, 0.0001)
    }

    private static func metersToSceneUnits(_ meters: Float, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = Float(Swift.max(metersPerUnit, 0.000_001))
        return meters / safeMetersPerUnit
    }
}
