import ComposableArchitecture
import Foundation

@Reducer
public struct StageViewFeature {
    @ObservableState
    public struct State: Equatable {
        public var modelURL: URL?
        public var selectedPrimPath: String?
        public var isLoaded: Bool = false
        public var sceneBounds: SceneBounds = SceneBounds()
        public var metersPerUnit: Double = 1.0
        public var isZUp: Bool = false

        public init(
            modelURL: URL? = nil,
            selectedPrimPath: String? = nil,
            isLoaded: Bool = false,
            sceneBounds: SceneBounds = SceneBounds(),
            metersPerUnit: Double = 1.0,
            isZUp: Bool = false
        ) {
            self.modelURL = modelURL
            self.selectedPrimPath = selectedPrimPath
            self.isLoaded = isLoaded
            self.sceneBounds = sceneBounds
            self.metersPerUnit = metersPerUnit
            self.isZUp = isZUp
        }
    }

    public init() {}

    public enum Action {
        case discreteStateReceived(RealityKitDiscreteSnapshot)
        case entityPicked(String?)
        case selectionChanged(String?)
        case loadRequested(URL)
        case reloadRequested
        case frameRequested
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
                state.isLoaded = false
                return .none

            case .reloadRequested, .frameRequested:
                return .none
            }
        }
    }
}
