import Foundation
import RealityKit
import simd

// MARK: - Entity-Prim Mapping

/// Stores the reconstructed USD prim path on each imported entity.
/// Built once after `Entity(contentsOf:)` by walking the entity hierarchy,
/// which is a 1:1 structural mirror of the USD prim tree.
public struct USDPrimPathComponent: Component, Sendable {
    public let primPath: String
    public init(primPath: String) { self.primPath = primPath }
}

/// Names injected by RealityKit during USD import that don't correspond to prims.
private let realityKitInternalNames: Set<String> = [
    "usdPrimitiveAxis",
]

// MARK: - Discrete Snapshot

/// Snapshot of discrete (non-camera) state for TCA integration.
public struct RealityKitDiscreteSnapshot: Equatable, Sendable {
    public let sceneBounds: SceneBounds
    public let metersPerUnit: Double
    public let isZUp: Bool
    public let selectedPrimPath: String?
    public let isUserInteraction: Bool
    public let isLoaded: Bool

    public init(
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        isZUp: Bool,
        selectedPrimPath: String?,
        isUserInteraction: Bool = false,
        isLoaded: Bool
    ) {
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.selectedPrimPath = selectedPrimPath
        self.isUserInteraction = isUserInteraction
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
    public private(set) var isUserInteraction: Bool = false
    public var selectedPrimPath: String? {
        didSet { emitDiscreteSnapshotIfNeeded() }
    }

    /// Update selection from programmatic sync (e.g. TCA).
    public func setSelection(_ path: String?) {
        self.isUserInteraction = false
        self.selectedPrimPath = path
    }

    /// Update selection from viewport interaction (e.g. pick).
    public func userDidPick(_ path: String?) {
        self.isUserInteraction = true
        self.selectedPrimPath = path
    }
    
    // MARK: - File State
    public private(set) var currentFileURL: URL?
    public private(set) var isLoaded: Bool = false
    
    // MARK: - Internal State
    internal var reloadToken: UUID = UUID()
    internal var _resetCameraRequested: Bool = false
    internal var _frameSelectionRequested: Bool = false
    private var discreteStateObservers = DiscreteStateObservers()
    
    // MARK: - Prim Path Registry
    /// Bidirectional prim path ↔ entity mapping, built once per model load.
    private(set) var primPathToEntityID: [String: Entity.ID] = [:]
    private(set) var entityIDToPrimPath: [Entity.ID: String] = [:]
    
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
            buildPrimPathMapping(root: entity)
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
        buildPrimPathMapping(root: entity)
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
        primPathToEntityID.removeAll()
        entityIDToPrimPath.removeAll()
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
            isUserInteraction: isUserInteraction,
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

// MARK: - Prim Path Mapping

extension RealityKitProvider {
    /// Build bidirectional prim path ↔ entity mappings by walking the imported entity tree.
    ///
    /// Entity(contentsOf:) produces a hierarchy that is a 1:1 structural mirror of
    /// the USD prim tree. The anonymous root wrapper (empty name) is not a prim.
    /// RealityKit appends `_N` suffixes for sibling name collisions.
    internal func buildPrimPathMapping(root: Entity) {
        primPathToEntityID.removeAll()
        entityIDToPrimPath.removeAll()
        
        func walk(_ entity: Entity, parentPrimPath: String) {
            // Skip RealityKit-injected internal entities (e.g. usdPrimitiveAxis).
            guard !realityKitInternalNames.contains(entity.name) else { return }
            
            let primPath: String
            if entity.name.isEmpty {
                // Anonymous root wrapper — not a USD prim, just pass through.
                primPath = parentPrimPath
            } else {
                // Entity name = prim name. RealityKit may suffix with _N for duplicates.
                // Strip the _N suffix to recover the original prim name.
                let primName = stripDuplicateSuffix(entity.name, amongSiblingsOf: entity)
                primPath = parentPrimPath.isEmpty ? "/\(primName)" : "\(parentPrimPath)/\(primName)"
            }
            
            if !entity.name.isEmpty {
                primPathToEntityID[primPath] = entity.id
                entityIDToPrimPath[entity.id] = primPath
                entity.components.set(USDPrimPathComponent(primPath: primPath))
            }
            
            for child in entity.children {
                walk(child, parentPrimPath: primPath)
            }
        }
        
        // The loaded entity is a container/anchor (often named "LoadedModel" or empty).
        // Its children correspond to the root prims of the USD stage.
        // We start walking from the children with an empty parent path to match USD paths (e.g. "/RootNode").
        for child in root.children {
            walk(child, parentPrimPath: "")
        }
    }
    
    /// Resolve a USD prim path to its RealityKit entity via the cached mapping.
    public func entity(for primPath: String) -> Entity? {
        guard let root = rootEntity ?? modelEntity else { return nil }
        guard let entityID = primPathToEntityID[primPath] else { return nil }
        return findEntity(byID: entityID, in: root)
    }
    
    /// Get the USD prim path for an entity.
    public func primPath(for entity: Entity) -> String? {
        entityIDToPrimPath[entity.id]
    }
    
    /// Get the USD prim path for an entity ID.
    public func primPath(for entityID: Entity.ID) -> String? {
        entityIDToPrimPath[entityID]
    }
    
    /// Walk up an entity's ancestors to find the nearest mapped prim path.
    /// Useful for pick-to-select when the hit entity might be a descendant.
    public func nearestMappedPrimPath(from entity: Entity) -> String? {
        var current: Entity? = entity
        while let e = current {
            if let path = entityIDToPrimPath[e.id] {
                return path
            }
            current = e.parent
        }
        return nil
    }
    
    // MARK: - Private Helpers
    
    /// Strip RealityKit's `_N` duplicate suffix if it was added for sibling collisions.
    ///
    /// RealityKit appends `_1`, `_2`, etc. when multiple sibling prims share a name.
    /// We detect this by checking if other siblings share the base name.
    private func stripDuplicateSuffix(_ name: String, amongSiblingsOf entity: Entity) -> String {
        // Quick check: does the name end with _N pattern?
        guard let lastUnderscore = name.lastIndex(of: "_") else { return name }
        let suffixStart = name.index(after: lastUnderscore)
        guard suffixStart < name.endIndex,
              name[suffixStart...].allSatisfy(\.isNumber) else { return name }
        
        let baseName = String(name[..<lastUnderscore])
        
        // Only strip if a sibling has the same base name (confirming it's a RealityKit suffix).
        guard let parent = entity.parent else { return name }
        let hasSiblingWithBaseName = parent.children.contains { sibling in
            sibling.id != entity.id && (sibling.name == baseName || sibling.name.hasPrefix(baseName + "_"))
        }
        
        return hasSiblingWithBaseName ? baseName : name
    }
    
    private func findEntity(byID id: Entity.ID, in root: Entity) -> Entity? {
        if root.id == id { return root }
        for child in root.children {
            if let found = findEntity(byID: id, in: child) { return found }
        }
        return nil
    }
}
