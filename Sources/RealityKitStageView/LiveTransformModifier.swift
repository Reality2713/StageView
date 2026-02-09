import SwiftUI
import ComposableArchitecture
import RealityKit

struct LiveTransformModifier: ViewModifier {
    let store: StoreOf<StageViewFeature>?
    let provider: RealityKitProvider
    
    func body(content: Content) -> some View {
        content
            .task(id: store?.liveTransformRequestID) {
                if let transform = store?.liveTransform {
                    await MainActor.run {
                        provider.applyLiveTransform(transform)
                    }
                }
            }
    }
}

extension View {
    func withLiveTransform(store: StoreOf<StageViewFeature>?, provider: RealityKitProvider) -> some View {
        modifier(LiveTransformModifier(store: store, provider: provider))
    }
}
