import Foundation
import Testing
import simd
@testable import RealityKitStageView

@Suite
struct SceneSpaceDragMathTests {
    private let epsilon: Float = 1e-4

    // MARK: - Camera-basis scene delta

    @Test
    func sceneDeltaMapsScreenDragToCameraPlaneFrontOn() {
        // Identity camera rotation: right = +X, up = +Y. A rightward screen drag
        // moves +X; a downward screen drag (positive y) moves -Y.
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let delta = SceneSpaceDragMath.sceneDelta(
            screenDelta: SIMD2<Double>(100, 50),
            cameraRotation: rotation,
            distance: 4
        )

        let perPoint = 4.0 * SceneSpaceDragMath.sceneUnitsPerPointAtUnitDistance
        #expect(abs(delta.x - 100 * perPoint) < 1e-9)
        #expect(abs(delta.y - (-50 * perPoint)) < 1e-9)
        #expect(abs(delta.z) < 1e-9)
    }

    @Test
    func sceneDeltaScalesWithDistance() {
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let near = SceneSpaceDragMath.sceneDelta(
            screenDelta: SIMD2<Double>(100, 0),
            cameraRotation: rotation,
            distance: 1
        )
        let far = SceneSpaceDragMath.sceneDelta(
            screenDelta: SIMD2<Double>(100, 0),
            cameraRotation: rotation,
            distance: 10
        )
        // Same pixel drag covers 10x more scene distance when 10x farther out.
        #expect(abs(far.x - near.x * 10) < 1e-9)
    }

    @Test
    func sceneDeltaFollowsCameraOrbit() {
        // Yaw 90° about Y: camera's right axis rotates from +X to -Z.
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let delta = SceneSpaceDragMath.sceneDelta(
            screenDelta: SIMD2<Double>(100, 0),
            cameraRotation: rotation,
            distance: 4
        )
        let perPoint = 4.0 * SceneSpaceDragMath.sceneUnitsPerPointAtUnitDistance
        // A rightward drag now moves along world -Z, not +X.
        #expect(abs(delta.x) < 1e-6)
        #expect(abs(delta.y) < 1e-6)
        #expect(abs(delta.z - (-100 * perPoint)) < 1e-6)
    }

    @Test
    func sceneDeltaClampsDegenerateDistanceToFloor() {
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let delta = SceneSpaceDragMath.sceneDelta(
            screenDelta: SIMD2<Double>(100, 0),
            cameraRotation: rotation,
            distance: 0
        )
        let floor = Double(SceneSpaceDragMath.minimumProportionalDistance)
        let expected = 100 * floor * SceneSpaceDragMath.sceneUnitsPerPointAtUnitDistance
        #expect(delta.x > 0)
        #expect(abs(delta.x - expected) < 1e-12)
    }

    // MARK: - NDC conversion

    @Test
    func ndcCenterIsZero() {
        let ndc = SceneSpaceDragMath.ndc(
            forViewPoint: SIMD2<Double>(400, 300),
            size: SIMD2<Double>(800, 600)
        )
        #expect(abs(ndc.x) < epsilon)
        #expect(abs(ndc.y) < epsilon)
    }

    @Test
    func ndcCornersFlipYForViewDownConvention() {
        // Top-left view point (0,0) → NDC (-1, +1); bottom-right (W,H) → (+1, -1).
        let topLeft = SceneSpaceDragMath.ndc(
            forViewPoint: SIMD2<Double>(0, 0),
            size: SIMD2<Double>(800, 600)
        )
        #expect(abs(topLeft.x - -1) < epsilon)
        #expect(abs(topLeft.y - 1) < epsilon)

        let bottomRight = SceneSpaceDragMath.ndc(
            forViewPoint: SIMD2<Double>(800, 600),
            size: SIMD2<Double>(800, 600)
        )
        #expect(abs(bottomRight.x - 1) < epsilon)
        #expect(abs(bottomRight.y - -1) < epsilon)
    }

    @Test
    func ndcZeroSizeReturnsZero() {
        let ndc = SceneSpaceDragMath.ndc(
            forViewPoint: SIMD2<Double>(100, 100),
            size: SIMD2<Double>(0, 0)
        )
        #expect(ndc == .zero)
    }

    // MARK: - Camera ray construction

    @Test
    func cameraRayCenterPointsDownForwardAxis() {
        // Camera at (0,0,5) looking down -Z (identity rotation).
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(0, 0, 5, 1)
        let ray = SceneSpaceDragMath.cameraRay(
            ndc: SIMD2<Float>(0, 0),
            cameraWorldTransform: t,
            fovDegrees: 60,
            aspect: 1
        )
        #expect(simd_length(ray.origin - SIMD3<Float>(0, 0, 5)) < epsilon)
        // Forward is -Z.
        #expect(simd_length(ray.direction - SIMD3<Float>(0, 0, -1)) < epsilon)
    }

    @Test
    func cameraRayRightEdgeTiltsTowardPositiveX() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(0, 0, 5, 1)
        let ray = SceneSpaceDragMath.cameraRay(
            ndc: SIMD2<Float>(1, 0),
            cameraWorldTransform: t,
            fovDegrees: 90,
            aspect: 1
        )
        // At 90° fov, the right edge ray is 45° toward +X: normalized (sin45,0,-cos45).
        let expected = simd_normalize(SIMD3<Float>(tan(Float.pi / 4), 0, -1))
        #expect(simd_length(ray.direction - expected) < epsilon)
        #expect(ray.direction.x > 0)
    }

    @Test
    func cameraRayHonorsCameraOrientation() {
        // Yaw 90° about Y. Camera forward (-local Z) maps to world -X.
        let q = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        var t = simd_float4x4(q)
        t.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let ray = SceneSpaceDragMath.cameraRay(
            ndc: SIMD2<Float>(0, 0),
            cameraWorldTransform: t,
            fovDegrees: 60,
            aspect: 1
        )
        #expect(simd_length(ray.direction - SIMD3<Float>(-1, 0, 0)) < epsilon)
    }

    // MARK: - Ray/plane intersection (plane through entity, camera-facing)

    @Test
    func rayPlaneIntersectionRecoversPlanePointForCenterRay() {
        // Camera at origin looking down -Z; entity 5 units ahead. Camera-facing
        // plane normal = forward = -Z. Center ray must hit the entity position.
        let origin = SIMD3<Float>(0, 0, 0)
        let direction = SIMD3<Float>(0, 0, -1)
        let entity = SIMD3<Float>(0, 0, -5)
        let normal = SIMD3<Float>(0, 0, -1)
        let hit = SceneSpaceDragMath.rayPlaneIntersection(
            rayOrigin: origin,
            rayDirection: direction,
            planePoint: entity,
            planeNormal: normal
        )
        #expect(hit != nil)
        #expect(simd_length((hit ?? .zero) - entity) < epsilon)
    }

    @Test
    func rayPlaneIntersectionLandsOnPlaneForOffAxisRay() {
        // An off-axis ray still lands on the plane z = -5.
        let origin = SIMD3<Float>(0, 0, 0)
        let direction = simd_normalize(SIMD3<Float>(0.5, 0.25, -1))
        let entity = SIMD3<Float>(0, 0, -5)
        let normal = SIMD3<Float>(0, 0, -1)
        let hit = SceneSpaceDragMath.rayPlaneIntersection(
            rayOrigin: origin,
            rayDirection: direction,
            planePoint: entity,
            planeNormal: normal
        )
        #expect(hit != nil)
        // On the plane: z component equals the entity z.
        #expect(abs((hit?.z ?? 0) - entity.z) < epsilon)
        // And offset in x/y consistent with the ray slope at z = -5.
        let scaled = direction * (5 / 1) // t such that z = -5 since dir.z = -1 after normalize? guard below
        _ = scaled
        #expect((hit?.x ?? 0) > 0)
        #expect((hit?.y ?? 0) > 0)
    }

    @Test
    func rayPlaneIntersectionReturnsNilWhenParallel() {
        // Ray parallel to the plane (perpendicular to the normal) → no hit.
        let hit = SceneSpaceDragMath.rayPlaneIntersection(
            rayOrigin: SIMD3<Float>(0, 0, 0),
            rayDirection: SIMD3<Float>(1, 0, 0),
            planePoint: SIMD3<Float>(0, 0, -5),
            planeNormal: SIMD3<Float>(0, 0, -1)
        )
        #expect(hit == nil)
    }

    @Test
    func rayPlaneIntersectionReturnsNilWhenBehindOrigin() {
        // Plane behind the ray (entity at +Z while ray goes -Z) → no forward hit.
        let hit = SceneSpaceDragMath.rayPlaneIntersection(
            rayOrigin: SIMD3<Float>(0, 0, 0),
            rayDirection: SIMD3<Float>(0, 0, -1),
            planePoint: SIMD3<Float>(0, 0, 5),
            planeNormal: SIMD3<Float>(0, 0, -1)
        )
        #expect(hit == nil)
    }

    @Test
    func cameraRayThenPlaneIntersectionPinsCursorToEntityPlane() {
        // End-to-end: a cursor at the viewport center, camera at (0,0,5) facing
        // -Z, entity at origin. The recovered scene point is the entity itself.
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(0, 0, 5, 1)
        let ndc = SceneSpaceDragMath.ndc(
            forViewPoint: SIMD2<Double>(400, 300),
            size: SIMD2<Double>(800, 600)
        )
        let ray = SceneSpaceDragMath.cameraRay(
            ndc: ndc,
            cameraWorldTransform: t,
            fovDegrees: 60,
            aspect: 800.0 / 600.0
        )
        let hit = SceneSpaceDragMath.rayPlaneIntersection(
            rayOrigin: ray.origin,
            rayDirection: ray.direction,
            planePoint: .zero,
            planeNormal: SIMD3<Float>(0, 0, -1)
        )
        #expect(hit != nil)
        #expect(simd_length(hit ?? SIMD3<Float>(repeating: 99)) < 1e-3)
    }
}
