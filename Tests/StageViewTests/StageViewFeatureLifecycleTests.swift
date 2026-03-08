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
}
