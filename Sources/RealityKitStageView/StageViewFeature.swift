import ComposableArchitecture
import Foundation
import simd

/// Live transform data for runtime viewport updates (not persisted to USD)
public struct LiveTransformData: Equatable, Sendable {
    public var primPath: String
    public var position: SIMD3<Double>
    public var rotationDegrees: SIMD3<Double>
    public var scale: SIMD3<Double>

    public init(
        primPath: String,
        position: SIMD3<Double>,
        rotationDegrees: SIMD3<Double>,
        scale: SIMD3<Double>
    ) {
        self.primPath = primPath
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }
}

@Reducer
public struct StageViewFeature {
    public struct LoadCommand: Equatable {
        public enum Mode: Equatable {
            case fullLoad
            case refresh
        }

        public var id: UUID
        public var mode: Mode
        public var preserveCamera: Bool
        public var url: URL

        public init(id: UUID, mode: Mode, preserveCamera: Bool, url: URL) {
            self.id = id
            self.mode = mode
            self.preserveCamera = preserveCamera
            self.url = url
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var activeLoadCommand: LoadCommand?
        public var cameraResetRequestID: UUID?
        public var isLoaded: Bool
        public var isZUp: Bool
        public var lastCompletedCommandID: UUID?
        public var liveTransform: LiveTransformData?
        public var liveTransformRequestID: UUID?
        public var loadRequestID: UUID
        public var metersPerUnit: Double
        public var modelURL: URL?
        public var pendingSelection: String?
        public var sceneBounds: SceneBounds
        public var selectedPrimPath: String?

        public init(
            activeLoadCommand: LoadCommand? = nil,
            cameraResetRequestID: UUID? = nil,
            isLoaded: Bool = false,
            isZUp: Bool = false,
            lastCompletedCommandID: UUID? = nil,
            liveTransform: LiveTransformData? = nil,
            liveTransformRequestID: UUID? = nil,
            loadRequestID: UUID = UUID(),
            metersPerUnit: Double = 1.0,
            modelURL: URL? = nil,
            pendingSelection: String? = nil,
            sceneBounds: SceneBounds = SceneBounds(),
            selectedPrimPath: String? = nil
        ) {
            self.activeLoadCommand = activeLoadCommand
            self.cameraResetRequestID = cameraResetRequestID
            self.isLoaded = isLoaded
            self.isZUp = isZUp
            self.lastCompletedCommandID = lastCompletedCommandID
            self.liveTransform = liveTransform
            self.liveTransformRequestID = liveTransformRequestID
            self.loadRequestID = loadRequestID
            self.metersPerUnit = metersPerUnit
            self.modelURL = modelURL
            self.pendingSelection = pendingSelection
            self.sceneBounds = sceneBounds
            self.selectedPrimPath = selectedPrimPath
        }
    }

    public init() {}

    public enum Action {
        /// Apply a live transform to the viewport (runtime only, not persisted)
        case applyLiveTransform(LiveTransformData)
        case clearRequested
        case discreteStateReceived(RealityKitDiscreteSnapshot)
        case entityPicked(String?)
        case frameRequested
        case loadCommandCompleted(UUID)
        case loadCommandFailed(UUID, String)
        case loadRequested(commandID: UUID, url: URL, preserveCamera: Bool)
        case refreshRequested(commandID: UUID, url: URL, preserveCamera: Bool)
        case resetCameraRequested
        case selectionChanged(String?)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .applyLiveTransform(transform):
                state.liveTransform = transform
                state.liveTransformRequestID = UUID()
                return .none

            case .clearRequested:
                state.activeLoadCommand = nil
                state.cameraResetRequestID = nil
                state.isLoaded = false
                state.isZUp = false
                state.loadRequestID = UUID()
                state.metersPerUnit = 1.0
                state.modelURL = nil
                state.pendingSelection = nil
                state.sceneBounds = SceneBounds()
                state.selectedPrimPath = nil
                return .none

            case let .discreteStateReceived(snapshot):
                state.isLoaded = snapshot.isLoaded
                state.isZUp = snapshot.isZUp
                state.metersPerUnit = snapshot.metersPerUnit
                state.sceneBounds = snapshot.sceneBounds
                if snapshot.isUserInteraction {
                    state.pendingSelection = snapshot.selectedPrimPath
                    state.selectedPrimPath = snapshot.selectedPrimPath
                }
                return .none

            case let .entityPicked(path):
                state.pendingSelection = path
                state.selectedPrimPath = path
                return .none

            case .frameRequested:
                return .none

            case let .loadCommandCompleted(commandID):
                guard state.activeLoadCommand?.id == commandID else {
                    return .none
                }
                state.activeLoadCommand = nil
                state.isLoaded = true
                state.lastCompletedCommandID = commandID
                return .none

            case let .loadCommandFailed(commandID, _):
                guard state.activeLoadCommand?.id == commandID else {
                    return .none
                }
                state.activeLoadCommand = nil
                state.isLoaded = false
                return .none

            case let .loadRequested(commandID, url, preserveCamera):
                state.activeLoadCommand = LoadCommand(
                    id: commandID,
                    mode: .fullLoad,
                    preserveCamera: preserveCamera,
                    url: url
                )
                state.isLoaded = false
                state.loadRequestID = commandID
                state.modelURL = url
                return .none

            case let .refreshRequested(commandID, url, preserveCamera):
                state.activeLoadCommand = LoadCommand(
                    id: commandID,
                    mode: .refresh,
                    preserveCamera: preserveCamera,
                    url: url
                )
                state.isLoaded = false
                state.loadRequestID = commandID
                state.modelURL = url
                return .none

            case .resetCameraRequested:
                state.cameraResetRequestID = UUID()
                return .none

            case let .selectionChanged(path):
                state.pendingSelection = path
                state.selectedPrimPath = path
                return .none
            }
        }
    }
}
