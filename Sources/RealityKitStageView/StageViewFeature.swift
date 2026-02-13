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
    @ObservableState
    public struct State: Equatable {
        public var modelURL: URL?
        public var loadRequestID: UUID
        public var preserveCameraOnNextLoad: Bool
        public var selectedPrimPath: String?
        public var isLoaded: Bool = false
        public var sceneBounds: SceneBounds = SceneBounds()
        public var metersPerUnit: Double = 1.0
        public var isZUp: Bool = false
        
        /// Live transform for instant viewport updates during editing
        public var liveTransform: LiveTransformData?
        /// Trigger ID for applying live transforms (change triggers update)
        public var liveTransformRequestID: UUID?

        public init(
            modelURL: URL? = nil,
            loadRequestID: UUID = UUID(),
            preserveCameraOnNextLoad: Bool = false,
            selectedPrimPath: String? = nil,
            isLoaded: Bool = false,
            sceneBounds: SceneBounds = SceneBounds(),
            metersPerUnit: Double = 1.0,
            isZUp: Bool = false,
            liveTransform: LiveTransformData? = nil,
            liveTransformRequestID: UUID? = nil
        ) {
            self.modelURL = modelURL
            self.loadRequestID = loadRequestID
            self.preserveCameraOnNextLoad = preserveCameraOnNextLoad
            self.selectedPrimPath = selectedPrimPath
            self.isLoaded = isLoaded
            self.sceneBounds = sceneBounds
            self.metersPerUnit = metersPerUnit
            self.isZUp = isZUp
            self.liveTransform = liveTransform
            self.liveTransformRequestID = liveTransformRequestID
        }
    }

    public init() {}

    public enum Action {
        case discreteStateReceived(RealityKitDiscreteSnapshot)
        case entityPicked(String?)
        case selectionChanged(String?)
        case loadRequested(URL)
        case loadRequestedPreservingCamera(URL)
        case reloadRequested
        case frameRequested
        /// Apply a live transform to the viewport (runtime only, not persisted)
        case applyLiveTransform(LiveTransformData)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .discreteStateReceived(snapshot):
                state.isLoaded = snapshot.isLoaded
                state.sceneBounds = snapshot.sceneBounds
                state.metersPerUnit = snapshot.metersPerUnit
                state.isZUp = snapshot.isZUp
                if snapshot.isUserInteraction {
                    state.selectedPrimPath = snapshot.selectedPrimPath
                }
                return .none

            case let .entityPicked(path):
                state.selectedPrimPath = path
                return .none

            case let .selectionChanged(path):
                state.selectedPrimPath = path
                return .none

            case let .loadRequested(url):
                state.modelURL = url
                state.preserveCameraOnNextLoad = false
                state.isLoaded = false
                state.loadRequestID = UUID()
                return .none

            case let .loadRequestedPreservingCamera(url):
                state.modelURL = url
                state.preserveCameraOnNextLoad = true
                state.isLoaded = false
                state.loadRequestID = UUID()
                return .none

            case .reloadRequested:
                guard state.modelURL != nil else { return .none }
                state.preserveCameraOnNextLoad = false
                state.isLoaded = false
                state.loadRequestID = UUID()
                return .none

            case .frameRequested:
                return .none
                
            case let .applyLiveTransform(transform):
                state.liveTransform = transform
                state.liveTransformRequestID = UUID()
                return .none
            }
        }
    }
}
