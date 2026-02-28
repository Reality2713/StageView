import ComposableArchitecture
import SwiftUI

struct BlendShapeRuntimeModifier: ViewModifier {
    let store: StoreOf<StageViewFeature>
    let provider: RealityKitProvider

    func body(content: Content) -> some View {
        content
            .task(id: store.blendShapeRuntimeRequestID) {
                let updates = store.blendShapeRuntimeWeights
                guard !updates.isEmpty else { return }
                await MainActor.run {
                    provider.applyBlendShapeWeights(updates)
                }
            }
    }
}

extension View {
    func withRuntimeBlendShapes(
        store: StoreOf<StageViewFeature>,
        provider: RealityKitProvider
    ) -> some View {
        modifier(BlendShapeRuntimeModifier(store: store, provider: provider))
    }
}
