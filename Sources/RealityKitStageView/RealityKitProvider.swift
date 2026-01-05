import Foundation
import RealityKit
import simd

/// Observable provider for the RealityKit viewport.
/// Manages scene state and provides feedback to the consumer.
@Observable
@MainActor
public final class RealityKitProvider {
    // MARK: - Scene Feedback (Read-only)
    public private(set) var cameraRotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
    public private(set) var cameraDistance: Float = 5.0
    public private(set) var sceneBounds: SceneBounds = SceneBounds()
    public private(set) var metersPerUnit: Double = 1.0
    public private(set) var isZUp: Bool = false
    
    // MARK: - Model State
    public private(set) var modelEntity: Entity?
    public private(set) var rootEntity: Entity?
    public private(set) var loadError: String?
    
    // MARK: - Selection (Bidirectional)
    public var selectedPrimPath: String?
    
    // MARK: - File State
    public private(set) var currentFileURL: URL?
    public private(set) var isLoaded: Bool = false
    
    // MARK: - Internal State
    internal var reloadToken: UUID = UUID()
    internal var _resetCameraRequested: Bool = false
    internal var _frameSelectionRequested: Bool = false
    
    public init() {}
    
    // MARK: - Lifecycle
    
    /// Load a model (call this or set modelEntity directly)
    public func load(_ url: URL) async throws {
        currentFileURL = url
        loadError = nil
        
        do {
            let entity = try await Entity(contentsOf: url)
            self.modelEntity = entity
            self.isLoaded = true
            updateBoundsFromModel(entity)
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }
    
    /// Set an externally loaded model
    public func setModel(_ entity: Entity, metersPerUnit: Double, isZUp: Bool) {
        self.modelEntity = entity
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.isLoaded = true
        updateBoundsFromModel(entity)
    }
    
    /// Clear the current model
    public func teardown() {
        modelEntity = nil
        rootEntity = nil
        currentFileURL = nil
        isLoaded = false
        selectedPrimPath = nil
        loadError = nil
    }
    
    // MARK: - Camera Control
    
    public func resetCamera() {
        _resetCameraRequested = true
    }
    
    public func frameSelection() {
        _frameSelectionRequested = true
    }
    
    // MARK: - Internal Updates
    
    internal func updateRootEntity(_ entity: Entity) {
        self.rootEntity = entity
    }
    
    internal func updateCameraState(rotation: simd_quatf, distance: Float) {
        self.cameraRotation = rotation
        self.cameraDistance = distance
    }
    
    private func updateBoundsFromModel(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        self.sceneBounds = SceneBounds(min: bounds.min, max: bounds.max)
    }
}
