import ComposableArchitecture
import Foundation
@testable import RealityKitStageView
import Testing

@Suite
@MainActor
struct StageViewFeatureLifecycleTests {
    @Test
    func entityPickDelegatesToAppWithoutMirroringRuntimeState() async {
        let store = TestStore(initialState: StageViewFeature.State()) {
            StageViewFeature()
        }

        await store.send(.entityPicked("/World/Cube"))
        await store.receive(\.delegate)
    }

    @Test
    func nilEntityPickDelegatesDeselectionToApp() async {
        let store = TestStore(initialState: StageViewFeature.State()) {
            StageViewFeature()
        }

        await store.send(.entityPicked(nil))
        await store.receive(.delegate(.userPickedPrim(nil)))
    }

    @Test
    func clearResetsOnlyCommandState() async {
        let url = URL(fileURLWithPath: "/tmp/model.usda")
        let store = TestStore(
            initialState: StageViewFeature.State(
                activeLoadCommand: .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
                    mode: .fullLoad,
                    preserveCamera: false,
                    url: url
                ),
                cameraResetRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
                liveTransform: .init(
                    primPath: "/World/Cube",
                    position: .zero,
                    rotationDegrees: .zero,
                    scale: SIMD3<Double>(repeating: 1)
                ),
                liveTransformRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
                blendShapeRuntimeWeights: [
                    .init(primPath: "/World/Cube", weightIndex: 0, weight: 0.5)
                ],
                blendShapeRuntimeRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000444")!,
                loadRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000555")!,
                modelURL: url,
                selectedPrimPath: "/World/Cube"
            )
        ) {
            StageViewFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.clearRequested) {
            $0.activeLoadCommand = nil
            $0.cameraResetRequestID = nil
            $0.liveTransform = nil
            $0.liveTransformRequestID = nil
            $0.blendShapeRuntimeWeights = []
            $0.blendShapeRuntimeRequestID = nil
            $0.loadRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            $0.modelURL = nil
            $0.selectedPrimPath = nil
        }
    }

    @Test
    func updateAppearanceChangesIntentWithoutTouchingRuntimeState() async {
        let appearance = StageViewAppearance.custom(
            StageViewAppearanceOverrides(
                background: .color(SIMD4<Float>(0.4, 0.5, 0.6, 1.0))
            )
        )
        let store = TestStore(initialState: StageViewFeature.State()) {
            StageViewFeature()
        }

        await store.send(.updateAppearance(appearance)) {
            $0.appearance = appearance
        }
    }
}
