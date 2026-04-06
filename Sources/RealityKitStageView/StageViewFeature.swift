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

/// Runtime blend-shape update payload for viewport-only preview.
public struct BlendShapeRuntimeWeight: Equatable, Sendable {
    public var primPath: String
    public var weightIndex: Int
    public var weight: Float

    public init(primPath: String, weightIndex: Int, weight: Float) {
        self.primPath = primPath
        self.weightIndex = weightIndex
        self.weight = weight
    }
}

@Reducer
public struct StageViewFeature {
    @Dependency(\.uuid) var uuid

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
	        /// Stable viewport appearance intent.
	        ///
	        /// Host applications should map user preferences and document overrides
	        /// into this value. `RealityKitStageView` resolves it against the current
	        /// SwiftUI environment locally, without sending hot-path actions.
	        public var appearance: StageViewAppearance
	        public var cameraResetRequestID: UUID?
	        /// Monotonic request token for environment/IBL reloads.
	        ///
	        /// Update this whenever `environmentURL` changes so the view can reload
	        /// document-scoped lighting without polling or per-frame reducer traffic.
	        public var environmentRequestID: UUID?
	        /// Per-viewport environment map intent.
	        ///
	        /// Hosts should derive this from document or scene state and keep it in
	        /// the stage feature. `RealityKitConfiguration` is not the source of
	        /// truth for mutable IBL in the TCA-first integration.
	        public var environmentURL: URL?
        public var liveTransform: LiveTransformData?
        public var liveTransformRequestID: UUID?
        public var blendShapeRuntimeWeights: [BlendShapeRuntimeWeight]
        public var blendShapeRuntimeRequestID: UUID?
        public var loadRequestID: UUID
        public var modelURL: URL?
        public var navigationMapping: RealityKitNavigationMapping
        public var sceneBounds: SceneBounds
        public var selectedPrimPath: String?

        public init(
            activeLoadCommand: LoadCommand? = nil,
            appearance: StageViewAppearance = .automatic,
            cameraResetRequestID: UUID? = nil,
            environmentRequestID: UUID? = nil,
            environmentURL: URL? = nil,
            liveTransform: LiveTransformData? = nil,
            liveTransformRequestID: UUID? = nil,
            blendShapeRuntimeWeights: [BlendShapeRuntimeWeight] = [],
            blendShapeRuntimeRequestID: UUID? = nil,
            loadRequestID: UUID = UUID(),
            modelURL: URL? = nil,
            navigationMapping: RealityKitNavigationMapping = .apple,
            sceneBounds: SceneBounds = .init(),
            selectedPrimPath: String? = nil
        ) {
            self.activeLoadCommand = activeLoadCommand
            self.appearance = appearance
            self.cameraResetRequestID = cameraResetRequestID
            self.environmentRequestID = environmentRequestID
            self.environmentURL = environmentURL
            self.liveTransform = liveTransform
            self.liveTransformRequestID = liveTransformRequestID
            self.blendShapeRuntimeWeights = blendShapeRuntimeWeights
            self.blendShapeRuntimeRequestID = blendShapeRuntimeRequestID
            self.loadRequestID = loadRequestID
            self.modelURL = modelURL
            self.navigationMapping = navigationMapping
            self.sceneBounds = sceneBounds
            self.selectedPrimPath = selectedPrimPath
        }
    }

    public init() {}

    public enum Action {
        /// Apply a live transform to the viewport (runtime only, not persisted)
        case applyLiveTransform(LiveTransformData)
        /// Apply runtime blend-shape weights to the viewport (not persisted to USD)
        case applyBlendShapeWeights([BlendShapeRuntimeWeight])
        case clearRequested
        case delegate(Delegate)
        case entityPicked(String?)
        case frameRequested
        case loadCommandCompleted(UUID)
        case loadCommandFailed(UUID, String)
        case loadRequested(commandID: UUID, url: URL, preserveCamera: Bool)
        case refreshRequested(commandID: UUID, url: URL, preserveCamera: Bool)
        case resetCameraRequested
        case selectionChanged(String?)
        case setSceneBounds(SceneBounds)
        case updateEnvironmentURL(URL?)
        /// Updates the viewport's appearance intent.
        ///
        /// Use this for app-driven preference or document override changes.
        /// Do not send actions for transient host environment changes such as
        /// light/dark resolution; the view derives those locally.
        case updateAppearance(StageViewAppearance)
        case updateNavigationMapping(RealityKitNavigationMapping)
        case viewportAppeared

        public enum Delegate: Equatable {
            case userPickedPrim(String?)
        }
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .applyLiveTransform(transform):
                state.liveTransform = transform
                state.liveTransformRequestID = uuid()
                return .none

            case let .applyBlendShapeWeights(weights):
                state.blendShapeRuntimeWeights = weights
                state.blendShapeRuntimeRequestID = uuid()
                return .none

            case .clearRequested:
                state.activeLoadCommand = nil
                state.cameraResetRequestID = nil
                state.environmentRequestID = nil
                state.environmentURL = nil
                state.loadRequestID = uuid()
                state.liveTransform = nil
                state.liveTransformRequestID = nil
                state.blendShapeRuntimeWeights = []
                state.blendShapeRuntimeRequestID = nil
                state.modelURL = nil
                state.sceneBounds = .init()
                state.selectedPrimPath = nil
                return .none

            case let .entityPicked(path):
                return .send(.delegate(.userPickedPrim(path)))

            case .frameRequested:
                return .none

            case let .loadCommandCompleted(commandID):
                guard state.activeLoadCommand?.id == commandID else {
                    return .none
                }
                state.activeLoadCommand = nil
                return .none

            case let .loadCommandFailed(commandID, _):
                guard state.activeLoadCommand?.id == commandID else {
                    return .none
                }
                state.activeLoadCommand = nil
                return .none

            case let .loadRequested(commandID, url, preserveCamera):
                state.activeLoadCommand = LoadCommand(
                    id: commandID,
                    mode: .fullLoad,
                    preserveCamera: preserveCamera,
                    url: url
                )
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
                state.loadRequestID = commandID
                state.modelURL = url
                return .none

            case .resetCameraRequested:
                state.cameraResetRequestID = uuid()
                return .none

            case let .selectionChanged(path):
                state.selectedPrimPath = path
                return .none

            case let .setSceneBounds(bounds):
                state.sceneBounds = bounds
                return .none

            case let .updateEnvironmentURL(url):
                guard state.environmentURL != url else { return .none }
                state.environmentURL = url
                state.environmentRequestID = uuid()
                return .none

            case let .updateAppearance(appearance):
                state.appearance = appearance
                return .none

            case let .updateNavigationMapping(mapping):
                state.navigationMapping = mapping
                return .none

            case .viewportAppeared:
                guard state.activeLoadCommand != nil else { return .none }
                state.loadRequestID = uuid()
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
