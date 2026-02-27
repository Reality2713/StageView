import ComposableArchitecture
import Foundation
@testable import RealityKitStageView
import Testing

@Suite
@MainActor
struct StageViewFeatureLifecycleTests {
    @Test
    func replaysLastSuccessfulLoadOnViewAppear() async {
        let url = URL(fileURLWithPath: "/tmp/model.usda")
        let last = StageViewFeature.LoadCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            mode: .fullLoad,
            preserveCamera: false,
            url: url
        )

        let store = TestStore(
            initialState: StageViewFeature.State(
                isLoaded: true,
                lastCompletedCommandID: last.id,
                lastSuccessfulLoadCommand: last,
                modelURL: url
            )
        ) {
            StageViewFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.viewAppeared) {
            $0.viewIsMounted = true
            let replayID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            $0.activeLoadCommand = .init(
                id: replayID,
                mode: .fullLoad,
                preserveCamera: true,
                url: url
            )
            $0.loadRequestID = replayID
        }
    }

    @Test
    func clearResetsReplayState() async {
        let url = URL(fileURLWithPath: "/tmp/model.usda")
        let command = StageViewFeature.LoadCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            mode: .fullLoad,
            preserveCamera: false,
            url: url
        )
        let store = TestStore(
            initialState: StageViewFeature.State(
                isLoaded: true,
                lastCompletedCommandID: command.id,
                lastSuccessfulLoadCommand: command,
                loadRequestID: command.id,
                modelURL: url
            )
        ) {
            StageViewFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.clearRequested) {
            $0.activeLoadCommand = nil
            $0.cameraResetRequestID = nil
            $0.isLoaded = false
            $0.isZUp = false
            $0.lastSuccessfulLoadCommand = nil
            $0.loadRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            $0.metersPerUnit = 1.0
            $0.modelURL = nil
            $0.pendingSelection = nil
            $0.sceneBounds = SceneBounds()
            $0.selectedPrimPath = nil
        }

        #expect(store.state.lastSuccessfulLoadCommand == nil)
        #expect(store.state.modelURL == nil)
        #expect(store.state.isLoaded == false)
    }
}
