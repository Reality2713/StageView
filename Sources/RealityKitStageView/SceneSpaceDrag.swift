import Foundation
import simd

/// Pure, platform-independent math for converting a screen-space drag into a
/// scene-space result.
///
/// This is the math core behind the viewport's *entity drag* interaction mode
/// (see ``RealityKitConfiguration/ViewportInteractionMode``). It deliberately
/// contains **no** RealityKit, SwiftUI, or AppKit/UIKit types so it can be unit
/// tested in isolation: every function is a deterministic transform of plain
/// `simd` values.
///
/// Two complementary projections are provided:
///
/// - ``sceneDelta(screenDelta:cameraRotation:distance:)`` — a fast, distance
///   proportional camera-basis delta. A fixed-pixel drag moves the result
///   farther when the camera is zoomed out, and the motion always lies in the
///   camera's view plane (so it stays intuitive from any orbit angle). This is
///   the projection an entity-source host typically feeds into its own runtime
///   as an *incremental* move.
///
/// - ``cameraRay(ndc:cameraWorldTransform:fovDegrees:aspect:)`` plus
///   ``rayPlaneIntersection(rayOrigin:rayDirection:planePoint:planeNormal:)`` —
///   an exact screen→scene *point*. The host can build a camera-facing plane
///   through the dragged entity and intersect successive cursor rays with it to
///   recover absolute scene-space points (and thus an exact delta that keeps the
///   entity pinned under the cursor). This mirrors the camera-ray construction
///   StageView already uses for macOS picking.
public enum SceneSpaceDragMath {
    /// A ray in world space.
    public struct Ray: Equatable, Sendable {
        public var origin: SIMD3<Float>
        public var direction: SIMD3<Float>

        public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
            self.origin = origin
            self.direction = direction
        }
    }

    /// Default scene-units-per-point gain at unit camera distance.
    ///
    /// The effective gain is `distance * sceneUnitsPerPointAtUnitDistance`, so a
    /// drag covers more scene distance the farther the camera is pulled back.
    public static let sceneUnitsPerPointAtUnitDistance: Double = 0.00125

    /// Minimum camera distance used by the proportional delta, so a degenerate
    /// (near-zero) distance can't collapse the drag to nothing.
    public static let minimumProportionalDistance: Float = 0.001

    /// Project an incremental screen drag onto the camera's view plane and return
    /// the equivalent scene-space delta.
    ///
    /// The result lies in the plane spanned by the camera's world right/up axes,
    /// so the move tracks the current orbit rather than assuming a front-on view.
    ///
    /// - Parameters:
    ///   - screenDelta: Incremental cursor delta in view points. `x` is positive
    ///     to the right; `y` is positive **downward** (AppKit/UIKit convention).
    ///   - cameraRotation: The camera's world orientation. The camera looks down
    ///     its local `-Z`; its right/up axes are derived from this quaternion.
    ///   - distance: Orbit distance from the camera to its focus, used to scale
    ///     the move so a fixed-pixel drag feels consistent at any zoom.
    public static func sceneDelta(
        screenDelta: SIMD2<Double>,
        cameraRotation: simd_quatf,
        distance: Float
    ) -> SIMD3<Double> {
        let right = cameraRotation.act(SIMD3<Float>(1, 0, 0))
        let up = cameraRotation.act(SIMD3<Float>(0, 1, 0))

        let perPoint = Double(Swift.max(distance, minimumProportionalDistance))
            * sceneUnitsPerPointAtUnitDistance
        let dRight = screenDelta.x * perPoint
        // Screen +y points down; dragging down should move the entity down, so
        // negate to align with the camera's (upward) up axis.
        let dUp = -screenDelta.y * perPoint

        func d(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
        }
        return d(right) * dRight + d(up) * dUp
    }

    /// Convert a normalized device coordinate to a world-space ray.
    ///
    /// This matches the perspective camera ray StageView builds for macOS
    /// picking: the camera looks down its local `-Z`, with the horizontal field
    /// of view scaled by aspect ratio.
    ///
    /// - Parameters:
    ///   - ndc: Normalized device coordinates in `[-1, 1]`, y-up.
    ///   - cameraWorldTransform: The camera's world transform (column-major).
    ///   - fovDegrees: Vertical field of view, in degrees.
    ///   - aspect: Viewport aspect ratio (width / height).
    public static func cameraRay(
        ndc: SIMD2<Float>,
        cameraWorldTransform t: simd_float4x4,
        fovDegrees: Float,
        aspect: Float
    ) -> Ray {
        let tanHalfFov = tan(fovDegrees * (.pi / 180) / 2)
        let localDir = SIMD3<Float>(ndc.x * tanHalfFov * aspect, ndc.y * tanHalfFov, -1)

        let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let worldDir = simd_normalize(SIMD3<Float>(
            t.columns.0.x * localDir.x + t.columns.1.x * localDir.y + t.columns.2.x * localDir.z,
            t.columns.0.y * localDir.x + t.columns.1.y * localDir.y + t.columns.2.y * localDir.z,
            t.columns.0.z * localDir.x + t.columns.1.z * localDir.y + t.columns.2.z * localDir.z
        ))
        return Ray(origin: camPos, direction: worldDir)
    }

    /// Convert a view-point location to normalized device coordinates (y-up).
    ///
    /// - Parameters:
    ///   - point: Location in view points. `y` is positive **downward**.
    ///   - size: View size in points.
    public static func ndc(forViewPoint point: SIMD2<Double>, size: SIMD2<Double>) -> SIMD2<Float> {
        guard size.x > 0, size.y > 0 else { return .zero }
        let x = Float(point.x / size.x) * 2 - 1
        // Flip y so downward view points map to a y-up NDC.
        let y = 1 - Float(point.y / size.y) * 2
        return SIMD2<Float>(x, y)
    }

    /// Intersect a ray with an infinite plane.
    ///
    /// Returns `nil` when the ray is parallel to the plane or the intersection
    /// lies behind the ray origin.
    ///
    /// - Parameters:
    ///   - rayOrigin: World-space ray origin.
    ///   - rayDirection: World-space ray direction (need not be normalized).
    ///   - planePoint: A point on the plane (e.g. the dragged entity's position).
    ///   - planeNormal: The plane normal (e.g. the camera's forward axis for a
    ///     camera-facing plane).
    public static func rayPlaneIntersection(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        planePoint: SIMD3<Float>,
        planeNormal: SIMD3<Float>
    ) -> SIMD3<Float>? {
        let denom = simd_dot(rayDirection, planeNormal)
        guard Swift.abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(planePoint - rayOrigin, planeNormal) / denom
        guard t.isFinite, t >= 0 else { return nil }
        return rayOrigin + rayDirection * t
    }
}
