import Foundation

public enum ViewportAppearance: Sendable {
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
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let halfFOV = horizontalFOVDegrees * .pi / 360.0
        let framedDistance = radiusUnits / Swift.max(tan(halfFOV), 0.001)
        return Swift.max(
            framedDistance * 1.15,
            minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit) * 2.0
        )
    }

    static func minimumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = metersPerUnit > 0 ? metersPerUnit : 1.0
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds, metersPerUnit: safeMetersPerUnit)
        let absoluteFloor = Float(0.002 / safeMetersPerUnit)
        return Swift.max(absoluteFloor, radiusUnits * 0.12)
    }

    static func maximumDistance(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = metersPerUnit > 0 ? metersPerUnit : 1.0
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds, metersPerUnit: safeMetersPerUnit)
        let absoluteCeiling = Float(250.0 / safeMetersPerUnit)
        return Swift.max(absoluteCeiling, radiusUnits * 400.0)
    }

    static func panScale(distance: Float, sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        return Swift.max(distance * 0.00125, radiusUnits * 0.00075)
    }

    static func clippingRange(
        distance: Float,
        sceneBounds: SceneBounds,
        metersPerUnit: Double
    ) -> ViewportCameraClipping {
        let safeMetersPerUnit = metersPerUnit > 0 ? metersPerUnit : 1.0
        let radiusUnits = sceneRadiusUnits(sceneBounds: sceneBounds, metersPerUnit: safeMetersPerUnit)
        let safeDistance = Swift.max(distance, minimumDistance(sceneBounds: sceneBounds, metersPerUnit: safeMetersPerUnit))
        let absoluteNear = Float(0.0005 / safeMetersPerUnit)

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
            farClip = nearClip + 1.0
        }

        return ViewportCameraClipping(near: nearClip, far: farClip)
    }

    static func gridRadiusMeters(worldExtentMeters: Double) -> Double {
        Swift.max(5.0, worldExtentMeters * 1.75)
    }

    static func minorGridStepMeters(forGridRadius radiusMeters: Double) -> Double {
        switch radiusMeters {
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

    private static func sceneRadiusUnits(sceneBounds: SceneBounds, metersPerUnit: Double) -> Float {
        let safeMetersPerUnit = metersPerUnit > 0 ? metersPerUnit : 1.0
        let extentUnits = Swift.max(sceneBounds.maxExtent, 0.001)
        let radiusMeters = Swift.max(Double(extentUnits) * safeMetersPerUnit * 0.5, 0.001)
        return Float(radiusMeters / safeMetersPerUnit)
    }
}
