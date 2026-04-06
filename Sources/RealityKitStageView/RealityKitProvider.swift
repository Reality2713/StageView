import Foundation
import OSLog
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

private let providerLogger = Logger(subsystem: "RealityKitStageView", category: "Provider")
private let realityKitStageLoadTimeoutSeconds = 60

// MARK: - Discrete Snapshot

/// Snapshot of discrete (non-camera) state for TCA integration.
public struct RealityKitDiscreteSnapshot: Equatable, Sendable {
    public let sceneBounds: SceneBounds
    public let metersPerUnit: Double
    public let isZUp: Bool
    public let selectedPrimPath: String?
    public let hasEmbeddedAnimation: Bool
    public let isUserInteraction: Bool
    public let isLoaded: Bool

    public init(
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        isZUp: Bool,
        selectedPrimPath: String?,
        hasEmbeddedAnimation: Bool = false,
        isUserInteraction: Bool = false,
        isLoaded: Bool
    ) {
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.isZUp = isZUp
        self.selectedPrimPath = selectedPrimPath
        self.hasEmbeddedAnimation = hasEmbeddedAnimation
        self.isUserInteraction = isUserInteraction
        self.isLoaded = isLoaded
    }
}

/// Observable provider for the RealityKit viewport.
/// Manages scene state and provides feedback to the consumer.
@Observable
@MainActor
public final class RealityKitProvider {
    public typealias PickPathResolver = @MainActor (_ directPath: String, _ entity: Entity, _ provider: RealityKitProvider) -> String?

    private enum LoadError: LocalizedError {
        case timeout(seconds: Int)
        var errorDescription: String? {
            switch self {
            case let .timeout(seconds):
                return "Stage load timed out after \(seconds)s"
            }
        }
    }
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
    public private(set) var selectionGeneration: UInt64 = 0

    /// Update selection from programmatic sync (e.g. TCA).
    public func setSelection(_ path: String?) {
        if self.selectedPrimPath == path {
            self.isUserInteraction = false
            return
        }
        self.isUserInteraction = false
        self.selectedPrimPath = path
        self.selectionGeneration &+= 1
    }

    /// Update selection from viewport interaction (e.g. pick).
    public func userDidPick(_ path: String?) {
        providerLogger.debug("userDidPick path=\(path ?? "nil", privacy: .public)")
        self.isUserInteraction = true
        self.selectedPrimPath = path
        self.selectionGeneration &+= 1
    }
    
    // MARK: - File State
    public private(set) var currentFileURL: URL?
    public private(set) var isLoaded: Bool = false
    
    // MARK: - Internal State
    internal var reloadToken: UUID = UUID()
    internal var _resetCameraRequested: Bool = false
    internal var _frameSelectionRequested: Bool = false
    internal var _preserveCameraOnNextLoad: Bool = false
    private var activeViewportID: UUID?
    private var animationController: AnimationPlaybackController?
    public private(set) var hasEmbeddedAnimation: Bool = false
    private var discreteStateObservers = DiscreteStateObservers()
    
    /// Generation counter for stale-result detection
    /// Incremented on each load start; completions with stale generation are discarded
    private var currentLoadGeneration: UInt64 = 0
    
    // MARK: - Prim Path Registry
    /// Bidirectional prim path ↔ entity mapping, built once per model load.
    private(set) var primPathToEntityID: [String: Entity.ID] = [:]
    private(set) var entityIDToPrimPath: [Entity.ID: String] = [:]
    private var pickPathOverrides: [String: String] = [:]
    private var pickPathResolver: PickPathResolver?
    
    public init() {}

    /// Provide consumer-owned remappings from coarse importer paths to more
    /// semantic prim paths.
    public func setPickPathOverrides(_ overrides: [String: String]) {
        pickPathOverrides = overrides
    }

    /// Provide a consumer-owned resolver for upgrading picked prim paths when
    /// the imported RealityKit graph is coarser than the source scene graph.
    public func setPickPathResolver(_ resolver: PickPathResolver?) {
        pickPathResolver = resolver
    }

    public func activateViewport(_ id: UUID) {
        activeViewportID = id
    }

    public func deactivateViewport(_ id: UUID) {
        guard activeViewportID == id else { return }
        activeViewportID = nil
    }

    public func isActiveViewport(_ id: UUID) -> Bool {
        activeViewportID == id
    }
    
    // MARK: - Lifecycle
    
    /// Load a model (call this or set modelEntity directly)
    /// Uses generation-based stale-result detection
    public func load(_ url: URL) async throws {
        guard let activeViewportID else { return }
        try await load(url, viewportID: activeViewportID)
    }

    public func load(_ url: URL, viewportID: UUID) async throws {
        guard activeViewportID == viewportID else { return }
        let loadStart = Date()
        providerLogger.notice(
            "viewport_runtime phase=realitykit_provider_load_started url=\(url.path, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public)"
        )

        // Increment generation to invalidate any pending loads
        let generation = currentLoadGeneration &+ 1
        currentLoadGeneration = generation
        
        // Clear immediately to show empty viewport
        teardownState()
        emitDiscreteSnapshotIfNeeded()
        let clearedAt = Date()

        currentFileURL = url
        
        do {
            let entity = try await loadEntityAsync(url)
            let importedAt = Date()
            
            // Discard if generation changed (cancelled/stale)
            guard currentLoadGeneration == generation, activeViewportID == viewportID else {
                return
            }
            
            self.modelEntity = entity
            self.isLoaded = true
            let mappingStart = Date()
            buildPrimPathMapping(root: entity)
            let mappedAt = Date()
            updateSceneBoundsFromAttachedEntity(entity)
            let boundsAt = Date()
            emitDiscreteSnapshotIfNeeded()
            let snapshotAt = Date()
            providerLogger.notice(
                "viewport_runtime phase=realitykit_provider_load_complete teardown_ms=\(Int(clearedAt.timeIntervalSince(loadStart) * 1000), privacy: .public) import_ms=\(Int(importedAt.timeIntervalSince(clearedAt) * 1000), privacy: .public) mapping_ms=\(Int(mappedAt.timeIntervalSince(mappingStart) * 1000), privacy: .public) bounds_ms=\(Int(boundsAt.timeIntervalSince(mappedAt) * 1000), privacy: .public) snapshot_ms=\(Int(snapshotAt.timeIntervalSince(boundsAt) * 1000), privacy: .public) total_ms=\(Int(snapshotAt.timeIntervalSince(loadStart) * 1000), privacy: .public) url=\(url.path, privacy: .public)"
            )
        } catch {
            // Discard if generation changed
            guard currentLoadGeneration == generation, activeViewportID == viewportID else {
                return
            }
            
            loadError = error.localizedDescription
            emitDiscreteSnapshotIfNeeded()
            providerLogger.error(
                "viewport_runtime phase=realitykit_provider_load_failed url=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func loadEntityAsync(_ url: URL) async throws -> Entity {
        let start = Date()
        let loaderTask = Task.detached(priority: .userInitiated) {
            try await Entity(contentsOf: url)
        }
        do {
            let entity = try await withThrowingTaskGroup(of: Entity.self) { group in
                group.addTask {
                    try await loaderTask.value
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(realityKitStageLoadTimeoutSeconds))
                    throw LoadError.timeout(seconds: realityKitStageLoadTimeoutSeconds)
                }
                guard let result = try await group.next() else {
                    throw LoadError.timeout(seconds: realityKitStageLoadTimeoutSeconds)
                }
                group.cancelAll()
                loaderTask.cancel()
                return result
            }
            providerLogger.notice(
                "viewport_runtime phase=realitykit_entity_contents_of elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) url=\(url.path, privacy: .public)"
            )
            return entity
        } catch {
            loaderTask.cancel()
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
        updateSceneBoundsFromAttachedEntity(entity)
        emitDiscreteSnapshotIfNeeded()
    }

    /// Update scene metadata independently from URL/entity load.
    /// This keeps viewport policy in sync when authored metadata changes mid-session.
    public func updateSceneMetadata(metersPerUnit: Double, isZUp: Bool) {
        let safeMetersPerUnit = metersPerUnit > 0 ? metersPerUnit : 1.0
        guard self.metersPerUnit != safeMetersPerUnit || self.isZUp != isZUp else { return }
        self.metersPerUnit = safeMetersPerUnit
        self.isZUp = isZUp
        emitDiscreteSnapshotIfNeeded()
    }
    
    /// Clear the current model
    public func teardown() {
        activeViewportID = nil
        teardownState()
    }

    public func teardown(viewportID: UUID) {
        guard activeViewportID == viewportID else { return }
        teardownState()
    }

    private func teardownState() {
        stopEmbeddedAnimations()
        modelEntity = nil
        currentFileURL = nil
        isLoaded = false
        sceneBounds = SceneBounds()
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

    public func setPreserveCameraOnNextLoad(_ preserve: Bool) {
        _preserveCameraOnNextLoad = preserve
    }

    internal func consumePreserveCameraOnNextLoad() -> Bool {
        let preserve = _preserveCameraOnNextLoad
        _preserveCameraOnNextLoad = false
        return preserve
    }
    
    // MARK: - Internal Updates
    
    internal func updateRootEntity(_ entity: Entity) {
        self.rootEntity = entity
    }

    internal func updateRootEntity(_ entity: Entity, viewportID: UUID) {
        guard activeViewportID == viewportID else { return }
        self.rootEntity = entity
    }
    
    internal var cameraWorldTransform: simd_float4x4 = matrix_identity_float4x4

    /// Approximate visible subject depth for overlay scale references.
    ///
    /// This uses the front-most depth of the current scene bounds along the
    /// camera's forward axis rather than the orbit radius to the bounds center.
    /// For a map-like scale indicator this is a better proxy for the visible
    /// model surface the user is judging by eye.
    public var overlayReferenceDepthMeters: Double {
        let fallback = Double(cameraDistance)
        guard sceneBounds.isFrameable else { return fallback }

        let cameraPosition = SIMD3<Float>(
            cameraWorldTransform.columns.3.x,
            cameraWorldTransform.columns.3.y,
            cameraWorldTransform.columns.3.z
        )
        let forward = simd_normalize(
            SIMD3<Float>(
                -cameraWorldTransform.columns.2.x,
                -cameraWorldTransform.columns.2.y,
                -cameraWorldTransform.columns.2.z
            )
        )
        guard forward.x.isFinite, forward.y.isFinite, forward.z.isFinite else {
            return fallback
        }

        let centerDepth = simd_dot(sceneBounds.center - cameraPosition, forward)
        let extents = sceneBounds.max - sceneBounds.min
        let halfExtents = extents * 0.5
        let projectedHalfDepth =
            Swift.abs(forward.x) * halfExtents.x
            + Swift.abs(forward.y) * halfExtents.y
            + Swift.abs(forward.z) * halfExtents.z
        let frontDepth = centerDepth - projectedHalfDepth
        let clamped = Swift.max(frontDepth, 0.000_001)
        return clamped.isFinite ? Double(clamped) : fallback
    }

    internal func updateCameraState(rotation: simd_quatf, distance: Float) {
        self.cameraRotation = rotation
        self.cameraDistance = distance
    }
    
    internal func updateSceneBoundsFromAttachedEntity(_ entity: Entity) {
        let start = Date()
        let worldBounds = entity.visualBounds(relativeTo: nil)
        let localBounds = entity.visualBounds(relativeTo: entity)
        logEntityBoundsDiagnostics(entity)

        let nextBounds = SceneBounds(min: worldBounds.min, max: worldBounds.max)
        if nextBounds.isFrameable {
            self.sceneBounds = nextBounds
        } else if sceneBounds.isFrameable {
            providerLogger.error(
                "Ignoring invalid scene bounds from attached entity; preserving last valid bounds. min=\(String(describing: worldBounds.min), privacy: .public) max=\(String(describing: worldBounds.max), privacy: .public) extent=\(String(describing: worldBounds.extents), privacy: .public)"
            )
        } else {
            providerLogger.error(
                "Ignoring invalid scene bounds from attached entity with no prior valid bounds. min=\(String(describing: worldBounds.min), privacy: .public) max=\(String(describing: worldBounds.max), privacy: .public) extent=\(String(describing: worldBounds.extents), privacy: .public)"
            )
            self.sceneBounds = SceneBounds()
        }
        providerLogger.notice(
            "viewport_runtime phase=realitykit_scene_bounds elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) frameable=\(self.sceneBounds.isFrameable, privacy: .public) world_min=\(String(describing: worldBounds.min), privacy: .public) world_max=\(String(describing: worldBounds.max), privacy: .public) local_min=\(String(describing: localBounds.min), privacy: .public) local_max=\(String(describing: localBounds.max), privacy: .public)"
        )
        emitDiscreteSnapshotIfNeeded()
    }

    private func logEntityBoundsDiagnostics(_ entity: Entity) {
        let rootTransform = entity.transform
        providerLogger.notice(
            "viewport_entity_bounds root name=\(entity.name, privacy: .public) children=\(entity.children.count, privacy: .public) scale=\(String(describing: rootTransform.scale), privacy: .public) translation=\(String(describing: rootTransform.translation), privacy: .public)"
        )
        for child in entity.children.prefix(8) {
            logEntityBoundsDiagnostics(child, depth: 1)
        }
    }

    private func logEntityBoundsDiagnostics(_ entity: Entity, depth: Int) {
        let localBounds = entity.visualBounds(relativeTo: entity)
        let worldBounds = entity.visualBounds(relativeTo: nil)
        let transform = entity.transform
        providerLogger.notice(
            "viewport_entity_bounds depth=\(depth, privacy: .public) name=\(entity.name, privacy: .public) children=\(entity.children.count, privacy: .public) scale=\(String(describing: transform.scale), privacy: .public) translation=\(String(describing: transform.translation), privacy: .public) local_min=\(String(describing: localBounds.min), privacy: .public) local_max=\(String(describing: localBounds.max), privacy: .public) world_min=\(String(describing: worldBounds.min), privacy: .public) world_max=\(String(describing: worldBounds.max), privacy: .public)"
        )
        guard depth < 2 else { return }
        for child in entity.children.prefix(8) {
            logEntityBoundsDiagnostics(child, depth: depth + 1)
        }
    }

    
    // MARK: - Live Transform (Runtime Only)
    
    /// Apply a transform directly to a RealityKit entity for instant visual feedback.
    /// This does NOT persist to USD – use this during interactive editing.
    public func applyLiveTransform(_ transform: LiveTransformData) {
        guard let entity = entity(for: transform.primPath) else {
            providerLogger.debug("No entity found for prim path: \(transform.primPath, privacy: .public)")
            return
        }
        
        let position = SIMD3<Float>(
            Float(transform.position.x),
            Float(transform.position.y),
            Float(transform.position.z)
        )
        
        // Convert Euler degrees to quaternion (ZYX rotation order to match USD's rotateXYZ)
        let degreesToRadians = Float.pi / 180.0
        let rx = Float(transform.rotationDegrees.x) * degreesToRadians
        let ry = Float(transform.rotationDegrees.y) * degreesToRadians
        let rz = Float(transform.rotationDegrees.z) * degreesToRadians
        
        // Compose quaternion from Euler angles (ZYX intrinsic = XYZ extrinsic)
        let qx = simd_quatf(angle: rx, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: ry, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: rz, axis: SIMD3<Float>(0, 0, 1))
        let rotation = qz * qy * qx  // ZYX order
        
        let scale = SIMD3<Float>(
            Float(transform.scale.x),
            Float(transform.scale.y),
            Float(transform.scale.z)
        )
        
        entity.transform = Transform(scale: scale, rotation: rotation, translation: position)
    }

    /// Apply runtime blend-shape weights for interactive inspection.
    /// This does NOT persist to USD.
    public func applyBlendShapeWeights(_ updates: [BlendShapeRuntimeWeight]) {
        guard !updates.isEmpty else { return }
        // Runtime blend-shape editing and animation playback are mutually exclusive.
        stopEmbeddedAnimations()

        for update in updates {
            guard let entity = resolveBlendShapeEntity(for: update.primPath) else { continue }
            guard var blendComp = entity.components[BlendShapeWeightsComponent.self] else { continue }
            guard !blendComp.weightSet.isEmpty else { continue }

            var weightSet = blendComp.weightSet
            var weights = Array(weightSet[0].weights)
            guard update.weightIndex >= 0, update.weightIndex < weights.count else { continue }
            weights[update.weightIndex] = update.weight
            weightSet[0].weights = BlendShapeWeights(weights)
            blendComp.weightSet = weightSet
            entity.components.set(blendComp)
        }
    }

    /// Start the default embedded animation from the first entity in the loaded
    /// hierarchy that exposes `availableAnimations`.
    public func startEmbeddedAnimationsIfAvailable(autoPlay: Bool = false) {
        guard let modelEntity else { return }
        startEmbeddedAnimations(on: modelEntity, autoPlay: autoPlay)
    }

    private func startEmbeddedAnimations(on entity: Entity, autoPlay: Bool) {
        stopEmbeddedAnimations()

        guard let target = firstAnimatedEntity(in: entity),
              let animation = target.availableAnimations.first else { return }

        hasEmbeddedAnimation = true

        animationController = target.playAnimation(
            animation.repeat(),
            transitionDuration: 0,
            startsPaused: !autoPlay
        )

        if autoPlay {
            providerLogger.info("Started embedded animation playback on \(target.name, privacy: .public)")
        } else {
            providerLogger.info("Prepared embedded animation (paused) on \(target.name, privacy: .public)")
        }
        emitDiscreteSnapshotIfNeeded()
    }

    private func stopEmbeddedAnimations() {
        animationController?.stop()
        animationController = nil
        hasEmbeddedAnimation = false
        emitDiscreteSnapshotIfNeeded()
    }

    public func setEmbeddedAnimationPlayback(isPlaying: Bool) {
        guard let animationController else { return }
        if isPlaying {
            animationController.resume()
        } else {
            animationController.pause()
        }
    }

    public func scrubEmbeddedAnimation(to seconds: TimeInterval) {
        guard let animationController else { return }
        animationController.pause()
        animationController.time = max(0, seconds)
    }

    private func firstAnimatedEntity(in entity: Entity) -> Entity? {
        if !entity.availableAnimations.isEmpty {
            return entity
        }
        for child in entity.children {
            if let found = firstAnimatedEntity(in: child) {
                return found
            }
        }
        return nil
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
            hasEmbeddedAnimation: hasEmbeddedAnimation,
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
        let start = Date()
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

        let mappedPaths = primPathToEntityID.keys.sorted()
        providerLogger.notice(
            "viewport_runtime phase=realitykit_prim_mapping elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) entries=\(mappedPaths.count, privacy: .public)"
        )
        if mappedPaths.count <= 4 || mappedPaths.contains(where: { $0.contains("/merged_") || $0.hasSuffix("/merged") }) {
            let sample = mappedPaths.prefix(8).joined(separator: ", ")
            providerLogger.info("Prim path mapping sample: \(sample, privacy: .public)")
        }
    }
    
    /// Resolve a USD prim path to its RealityKit entity via the cached mapping.
    public func entity(for primPath: String) -> Entity? {
        guard let root = rootEntity ?? modelEntity else { return nil }
        guard let entityID = primPathToEntityID[primPath] else { return nil }
        return findEntity(byID: entityID, in: root)
    }

    /// Resolve a USD prim path to the closest selectable RealityKit entity.
    ///
    /// This is more tolerant than `entity(for:)` and is intended for selection
    /// visualization when Hydra and RealityKit importer hierarchies diverge.
    public func selectionEntity(for primPath: String) -> Entity? {
        let normalized = normalizePrimPath(primPath)
        guard !normalized.isEmpty else { return nil }

        if let exact = entity(for: normalized) {
            return exact
        }

        if let ancestorPath = nearestAncestorMappedPath(for: normalized),
           let ancestor = entity(for: ancestorPath) {
            return ancestor
        }

        for shiftedPath in droppedLeadingSegmentCandidates(for: normalized) {
            if let direct = entity(for: shiftedPath) {
                return direct
            }
            if let ancestorPath = nearestAncestorMappedPath(for: shiftedPath),
               let ancestor = entity(for: ancestorPath) {
                return ancestor
            }
        }

        if let descendantPath = nearestDescendantMappedPath(for: normalized),
           let descendant = entity(for: descendantPath) {
            return descendant
        }

        if let suffixPath = bestSuffixMatchPath(for: normalized),
           let suffix = entity(for: suffixPath) {
            return suffix
        }

        return nil
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

    /// Resolve the best USD prim path for a viewport pick.
    ///
    /// RealityKit can collapse imported meshes into generic buckets such as
    /// `merged_1`, which makes a direct entity-to-prim lookup too coarse for
    /// selection. This resolver keeps the nearest mapped path when it is
    /// meaningful, but falls back to a more semantic sibling/descendant path
    /// when the importer only exposes a generic merged node.
    public func preferredPickPrimPath(from entity: Entity) -> String? {
        guard let directPath = nearestMappedPrimPath(from: entity) else { return nil }
        if let overridePath = remappedPickPath(for: directPath, entity: entity) {
            return overridePath
        }
        guard isGenericImportedPath(directPath) else { return directPath }

        if let semanticPath = preferredSemanticPath(near: directPath) {
            providerLogger.debug(
                "Resolved generic pick path \(directPath, privacy: .public) to semantic path \(semanticPath, privacy: .public)"
            )
            return semanticPath
        }

        return directPath
    }

    /// Resolve the best USD prim path from an ordered list of raycast hits.
    ///
    /// This prefers the first specific non-generic mapping in raycast order
    /// before falling back to merged/importer-generated buckets.
    public func preferredPickPrimPath(from entities: [Entity]) -> String? {
        var fallback: String?

        for entity in entities {
            guard let directPath = nearestMappedPrimPath(from: entity) else { continue }

            if let remapped = remappedPickPath(for: directPath, entity: entity) {
                if isGenericImportedPath(remapped) == false {
                    return remapped
                }
                fallback = fallback ?? remapped
                continue
            }

            if isGenericImportedPath(directPath) == false {
                return directPath
            }

            fallback = fallback ?? preferredPickPrimPath(from: entity)
        }

        return fallback
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

    private func normalizePrimPath(_ primPath: String) -> String {
        let trimmed = primPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        if withLeadingSlash.count > 1, withLeadingSlash.hasSuffix("/") {
            return String(withLeadingSlash.dropLast())
        }
        return withLeadingSlash
    }

    private func nearestAncestorMappedPath(for primPath: String) -> String? {
        var cursor = primPath
        while true {
            if primPathToEntityID[cursor] != nil {
                return cursor
            }
            guard let slash = cursor.lastIndex(of: "/"), slash != cursor.startIndex else {
                return nil
            }
            cursor = String(cursor[..<slash])
        }
    }

    private func droppedLeadingSegmentCandidates(for primPath: String) -> [String] {
        let components = primPath.split(separator: "/")
        guard components.count > 1 else { return [] }

        var candidates: [String] = []
        for index in 1..<components.count {
            let suffix = components[index...].joined(separator: "/")
            candidates.append("/\(suffix)")
        }
        return candidates
    }

    private func nearestDescendantMappedPath(for primPath: String) -> String? {
        let prefix = primPath == "/" ? "/" : primPath + "/"
        let requestedDepth = primPath.split(separator: "/").count

        return primPathToEntityID.keys
            .filter { $0.hasPrefix(prefix) }
            .min { lhs, rhs in
                let lhsDepth = lhs.split(separator: "/").count
                let rhsDepth = rhs.split(separator: "/").count
                let lhsDelta = abs(lhsDepth - requestedDepth)
                let rhsDelta = abs(rhsDepth - requestedDepth)
                if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
                return lhs.count < rhs.count
            }
    }

    private func bestSuffixMatchPath(for requestedPath: String) -> String? {
        let requestedComponents = requestedPath.split(separator: "/").map(String.init)
        guard let requestedLeaf = requestedComponents.last else { return nil }

        let candidates = primPathToEntityID.keys.filter { path in
            let comps = path.split(separator: "/")
            guard let leaf = comps.last else { return false }
            return leaf == requestedLeaf
        }
        guard !candidates.isEmpty else { return nil }

        func suffixScore(_ candidate: String) -> Int {
            let candidateComponents = candidate.split(separator: "/").map(String.init)
            var score = 0
            var i = requestedComponents.count - 1
            var j = candidateComponents.count - 1
            while i >= 0, j >= 0, requestedComponents[i] == candidateComponents[j] {
                score += 1
                i -= 1
                j -= 1
            }
            return score
        }

        return candidates.max { lhs, rhs in
            let lhsScore = suffixScore(lhs)
            let rhsScore = suffixScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }

            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            return lhsDepth > rhsDepth
        }
    }

    private func isGenericImportedPath(_ primPath: String) -> Bool {
        guard let leaf = primPath.split(separator: "/").last else { return false }
        return isGenericImportedName(String(leaf))
    }

    private func remappedPickPath(for directPath: String, entity: Entity) -> String? {
        if let overridePath = pickPathOverrides[directPath], overridePath.isEmpty == false {
            providerLogger.debug(
                "Resolved pick path \(directPath, privacy: .public) using override path \(overridePath, privacy: .public)"
            )
            return overridePath
        }

        if let resolvedPath = pickPathResolver?(directPath, entity, self),
           resolvedPath.isEmpty == false {
            providerLogger.debug(
                "Resolved pick path \(directPath, privacy: .public) using custom resolver path \(resolvedPath, privacy: .public)"
            )
            return resolvedPath
        }

        return nil
    }

    private func isGenericImportedName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "merged" || lowered.hasPrefix("merged_") {
            return true
        }
        if lowered == "mesh" || lowered.hasPrefix("mesh_") {
            return true
        }
        return false
    }

    private func preferredSemanticPath(near genericPath: String) -> String? {
        let parentPath: String
        if let slash = genericPath.lastIndex(of: "/"), slash != genericPath.startIndex {
            parentPath = String(genericPath[..<slash])
        } else {
            parentPath = "/"
        }

        let directChildren = semanticDirectChildren(of: parentPath)
        if let bestDirectChild = directChildren.min(by: semanticPathOrdering) {
            return bestDirectChild
        }

        let descendants = semanticDescendants(of: parentPath)
        if let bestDescendant = descendants.min(by: semanticPathOrdering) {
            return bestDescendant
        }

        if let ancestor = nearestNonGenericAncestorPath(for: parentPath) {
            return ancestor
        }

        return nil
    }

    private func semanticDirectChildren(of parentPath: String) -> [String] {
        let parentDepth = pathDepth(parentPath)
        let prefix = parentPath == "/" ? "/" : parentPath + "/"

        return primPathToEntityID.keys.filter { candidate in
            guard candidate.hasPrefix(prefix), candidate != parentPath else { return false }
            guard pathDepth(candidate) == parentDepth + 1 else { return false }
            return isGenericImportedPath(candidate) == false
        }
    }

    private func semanticDescendants(of parentPath: String) -> [String] {
        let prefix = parentPath == "/" ? "/" : parentPath + "/"
        return primPathToEntityID.keys.filter { candidate in
            guard candidate.hasPrefix(prefix), candidate != parentPath else { return false }
            return isGenericImportedPath(candidate) == false
        }
    }

    private func nearestNonGenericAncestorPath(for primPath: String) -> String? {
        var cursor = primPath
        while true {
            guard let slash = cursor.lastIndex(of: "/"), slash != cursor.startIndex else {
                return nil
            }
            cursor = String(cursor[..<slash])
            if primPathToEntityID[cursor] != nil, isGenericImportedPath(cursor) == false {
                return cursor
            }
        }
    }

    private func pathDepth(_ primPath: String) -> Int {
        primPath.split(separator: "/").count
    }

    private func semanticPathOrdering(lhs: String, rhs: String) -> Bool {
        let lhsDepth = pathDepth(lhs)
        let rhsDepth = pathDepth(rhs)
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    /// BlendShape prims can map to mesh entities, so we walk up path ancestry
    /// until we find an entity that carries BlendShapeWeightsComponent.
    private func resolveBlendShapeEntity(for primPath: String) -> Entity? {
        var cursor = primPath
        while !cursor.isEmpty {
            if let entity = entity(for: cursor),
               entity.components[BlendShapeWeightsComponent.self] != nil {
                return entity
            }
            guard let slash = cursor.lastIndex(of: "/"), slash != cursor.startIndex else {
                break
            }
            cursor = String(cursor[..<slash])
        }
        return nil
    }
}
