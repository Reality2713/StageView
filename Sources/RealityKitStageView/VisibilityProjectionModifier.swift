import ComposableArchitecture
import SwiftUI

struct VisibilityProjectionModifier: ViewModifier {
    let store: StoreOf<StageViewFeature>
    let provider: RealityKitProvider

    func body(content: Content) -> some View {
        content
            .task(id: store.hiddenPrimPaths) {
                await MainActor.run {
                    provider.setHiddenPrimPaths(Set(store.hiddenPrimPaths))
                }
            }
            .onChange(of: provider.modelComponentPrimPaths) { _, newPaths in
                store.send(.updateModelComponentPrimPaths(newPaths))
            }
    }
}

extension View {
    func withVisibilityProjection(
        store: StoreOf<StageViewFeature>,
        provider: RealityKitProvider
    ) -> some View {
        modifier(VisibilityProjectionModifier(store: store, provider: provider))
    }
}
