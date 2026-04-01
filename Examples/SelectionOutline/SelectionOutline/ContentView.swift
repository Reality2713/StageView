//
//  ContentView.swift
//  SelectionOutline
//

import ComposableArchitecture
import RealityKit
import RealityKitStageView
import SwiftUI

@Reducer
struct SelectionOutlineFeature {
  @ObservableState
  struct State {
    var selectedStyle: OutlineStyle = .boundingBox
    var errorMessage: String?
    var provider = RealityKitProvider()
    var stageView = StageViewFeature.State()
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case stageView(StageViewFeature.Action)
    case task
  }

  enum OutlineStyle: String, CaseIterable, Identifiable, Sendable {
    case boundingBox = "Bounding Box"
    case invertedHull = "Inverted Hull"
    case postProcess = "Post-Process"

    var selectionHighlightStyle: SelectionHighlightStyle {
      switch self {
      case .boundingBox:
        return .boundingBox
      case .invertedHull:
        return .outline
      case .postProcess:
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
          return .postProcessOutline
        }
        return .outline
      }
    }

    var id: String { rawValue }
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Scope(state: \.stageView, action: \.stageView) {
      StageViewFeature()
    }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let assetName = "gramophone"
        guard let url = Bundle.main.url(forResource: assetName, withExtension: "usdz") else {
          state.errorMessage = "Asset '\(assetName).usdz' not found in bundle"
          return .none
        }
        return .send(.stageView(.loadRequested(commandID: UUID(), url: url, preserveCamera: false)))

      case .stageView(.loadCommandFailed(_, let message)):
        state.errorMessage = "Failed to load: \(message)"
        return .none

      case .stageView:
        return .none
      }
    }
  }
}

struct ContentView: View {
  @Bindable var store: StoreOf<SelectionOutlineFeature>

  var body: some View {
    VStack(spacing: 0) {
      stylePicker

      GeometryReader { proxy in
        viewport
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .task {
      await store.send(.task).finish()
    }
  }

  private var stylePicker: some View {
    Picker("Outline Style", selection: $store.selectedStyle) {
      ForEach(SelectionOutlineFeature.OutlineStyle.allCases) { style in
        Text(style.rawValue).tag(style)
      }
    }
    .pickerStyle(.segmented)
    .padding()
  }

  private var viewport: some View {
    ZStack {
      RealityKitStageView(
        provider: store.provider,
        store: store.scope(state: \.stageView, action: \.stageView),
        configuration: RealityKitConfiguration(
          showGrid: true,
          showAxes: true,
          outlineConfiguration: OutlineConfiguration(
            color: .yellow,
            width: 0.03,
            referenceDistance: 2.0
          ),
          selectionHighlightStyle: store.selectedStyle.selectionHighlightStyle
        )
      )

      if let error = store.errorMessage {
        ErrorOverlay(message: error)
      }
    }
  }
}

struct ErrorOverlay: View {
  let message: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
      Text(message)
        .multilineTextAlignment(.center)
    }
    .padding()
    .background(.ultraThinMaterial)
    .cornerRadius(12)
  }
}

#Preview {
  ContentView(
    store: Store(initialState: SelectionOutlineFeature.State()) {
      SelectionOutlineFeature()
    }
  )
}
