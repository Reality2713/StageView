import Foundation
import RealityKit
import simd

/// Snapshot of discrete (non-camera) state for TCA integration.
public struct RealityKitDiscreteSnapshot: Equatable, Sendable {
    public let sceneBounds: SceneBounds
    public let metersPerUnit: Double
    public let isZUp: Bool
    public let selectedPrimPath: String?
    public let isLoaded: Bool

    public init(
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        isZUp: Bool,
        selectedPrimPath: String?,
        isLoaded: Bool
    ) {
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.selectedPrimPath = selectedPrimPath
        self.isLoaded = isLoaded
    }
}

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
    // NOTE: Selection changes do NOT emit snapshots to prevent feedback loops.
    // TCA is the source of truth for selection, synced here via setSelection().
    public var selectedPrimPath: String?
    
    // MARK: - File State
    public private(set) var currentFileURL: URL?
    public private(set) var isLoaded: Bool = false
    
    // MARK: - Internal State
    internal var reloadToken: UUID = UUID()
    internal var _resetCameraRequested: Bool = false
    internal var _frameSelectionRequested: Bool = false
    private var discreteStateObservers = DiscreteStateObservers()
    
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
            emitDiscreteSnapshotIfNeeded()
        } catch {
            loadError = error.localizedDescription
            emitDiscreteSnapshotIfNeeded()
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
        emitDiscreteSnapshotIfNeeded()
    }
    
    /// Clear the current model
    public func teardown() {
        modelEntity = nil
        rootEntity = nil
        currentFileURL = nil
        isLoaded = false
        selectedPrimPath = nil
        loadError = nil
        emitDiscreteSnapshotIfNeeded()
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
        emitDiscreteSnapshotIfNeeded()
    }
}

// MARK: - Discrete State Observation

extension RealityKitProvider {
    /// Observe discrete state changes (NOT camera).
    public func observeDiscreteState() -> AsyncStream<RealityKitDiscreteSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            discreteStateContinuations[id] = continuation
            continuation.yield(makeDiscreteSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.discreteStateContinuations[id] = nil
                }
            }
        }
    }
}

// MARK: - Discrete State Internals

extension RealityKitProvider {
    private var discreteStateContinuations: [UUID: AsyncStream<RealityKitDiscreteSnapshot>.Continuation] {
        get { discreteStateObservers.continuations }
        set { discreteStateObservers.continuations = newValue }
    }

    private func makeDiscreteSnapshot() -> RealityKitDiscreteSnapshot {
        RealityKitDiscreteSnapshot(
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit,
            isZUp: isZUp,
            selectedPrimPath: selectedPrimPath,
            isLoaded: isLoaded
        )
    }

    private func emitDiscreteSnapshotIfNeeded() {
        let snapshot = makeDiscreteSnapshot()
        if snapshot == discreteStateObservers.lastSnapshot {
            return
        }
        discreteStateObservers.lastSnapshot = snapshot
        for continuation in discreteStateContinuations.values {
            continuation.yield(snapshot)
        }
    }
}

private struct DiscreteStateObservers {
    var continuations: [UUID: AsyncStream<RealityKitDiscreteSnapshot>.Continuation] = [:]
    var lastSnapshot: RealityKitDiscreteSnapshot?
}
