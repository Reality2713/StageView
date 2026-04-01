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
        let radiusMeters = sceneRadiusMeters(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let halfFOV = horizontalFOVDegrees * .pi / 360.0
        let framedDistance = radiusMeters / Swift.max(tan(halfFOV), 0.001)
        let minDist = minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let result = Swift.max(
            framedDistance * 1.15,
            minDist * 2.0
        )
        tuningLogger.info("[ViewportTuning] defaultCameraDistance: maxExtent=\(sceneBounds.maxExtent) radiusMeters=\(radiusMeters) framedDist=\(framedDistance) minDist=\(minDist) → distance=\(result)")
        return result
    }

    static func minimumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusMeters = sceneRadiusMeters(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        // The absolute floor should be 2mm in WORLD space (meters).
        let absoluteFloorMeters = Float(0.002)
        return Swift.max(absoluteFloorMeters, radiusMeters * 0.12)
    }

    static func maximumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusMeters = sceneRadiusMeters(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let absoluteCeilingMeters = Float(500.0)
        return Swift.max(absoluteCeilingMeters, radiusMeters * 400.0)
    }

    static func panScale(distance: Float, sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusMeters = sceneRadiusMeters(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        return Swift.max(distance * 0.00125, radiusMeters * 0.00075)
    }

    static func clippingRange(
        distance: Float,
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        environmentRadius: Float? = nil
    ) -> ViewportCameraClipping {
        let radiusMeters = sceneRadiusMeters(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let safeDistance = Swift.max(distance, minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit))
        let absoluteNear = Float(0.0005)

        var nearClip = Swift.max(
            absoluteNear,
            Swift.min(safeDistance * 0.1, Swift.max(radiusMeters * 0.02, absoluteNear))
        )
        var farClip = Swift.max(
            safeDistance + radiusMeters * 40.0,
            radiusMeters * 120.0
        )

        let maxRatio: Float = 200_000
        if farClip / nearClip > maxRatio {
            nearClip = farClip / maxRatio
        }
        if farClip <= nearClip {
            farClip = nearClip + 1.0
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

    private static func sceneRadiusMeters(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = Float(Swift.max(metersPerUnit, 0.000_001))
        let extentMeters = Swift.max(sceneBounds.maxExtent * safeMetersPerUnit, 0.0001)
        return extentMeters * 0.5
    }
}
