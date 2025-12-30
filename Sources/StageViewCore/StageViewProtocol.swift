import Foundation

/// Main viewport protocol that both RealityKit and Hydra renderers can conform to.
public protocol StageViewport {
    // Configuration
    var gridConfiguration: GridConfiguration { get set }
    var iblConfiguration: IBLConfiguration { get set }

    // Camera
    func resetCamera()
    func frameSelection(primPath: String?)

    // Selection
    var selectedPrimPath: String? { get set }

    // Info (read-only feedback)
    var sceneBounds: SceneBounds { get }
    var metersPerUnit: Double { get }
    var isZUp: Bool { get }
}
