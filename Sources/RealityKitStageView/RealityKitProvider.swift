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

private let providerLogger = Logger(subsystem: "RealityKitStageView", category: "Provider")
private let renderableEntityQuery = EntityQuery(where: .has(ModelComponent.self))

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
    private static let cameraFocusEpsilon: Float = 0.000_5
    private static let cameraDistanceEpsilonRatio: Float = 0.01
    private static let minimumCameraDistanceEpsilon: Float = 0.000_5

    // MARK: - Scene Feedback (Read-only)
    public private(set) var cameraFocus: SIMD3<Float> = .zero
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
    private var externallySuppliedSceneBounds: SceneBounds?
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
    private var hiddenPrimPaths: Set<String> = []
    private var projectedHiddenEntityIDs: Set<Entity.ID> = []

    /// Prim paths that carry renderable geometry (`ModelComponent`) in the
    /// imported RealityKit entity graph. Populated from `EntityQuery` results.
    /// Empty until the first successful load completes.
    public private(set) var modelComponentPrimPaths: Set<String> = []
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
        try await load(url, viewportID: viewportID, clearsCurrentModelBeforeImport: true)
    }

    public func refresh(_ url: URL, viewportID: UUID) async throws {
        try await load(url, viewportID: viewportID, clearsCurrentModelBeforeImport: false)
    }

    private func load(
        _ url: URL,
        viewportID: UUID,
        clearsCurrentModelBeforeImport: Bool
    ) async throws {
        guard activeViewportID == viewportID else { return }
        let loadStart = Date()
        providerLogger.notice(
            "viewport_runtime phase=realitykit_provider_load_started url=\(url.path, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public)"
        )

        // Increment generation to invalidate any pending loads
        let generation = currentLoadGeneration &+ 1
        currentLoadGeneration = generation
        
        if clearsCurrentModelBeforeImport {
            teardownState()
            emitDiscreteSnapshotIfNeeded()
        } else {
            loadError = nil
        }
        let clearedAt = Date()

        currentFileURL = url
        
        do {
            let entity = try await loadEntityAsync(url)
            let importedAt = Date()
            
            // Discard if generation changed (cancelled/stale)
            guard currentLoadGeneration == generation, activeViewportID == viewportID else {
                providerLogger.notice(
                    "viewport_runtime phase=realitykit_provider_load_discarded reason=stale_result url=\(url.path, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) generation=\(generation, privacy: .public) current_generation=\(self.currentLoadGeneration, privacy: .public)"
                )
                throw CancellationError()
            }
            
            self.modelEntity = entity
            self.isLoaded = true
            let mappingStart = Date()
            refreshPrimPathMapping(root: entity)
            let mappedAt = Date()
            applyVisibilityProjection()
            let visibilityAt = Date()
            restoreExternallySuppliedSceneBounds()
            let boundsAt = Date()
            emitDiscreteSnapshotIfNeeded()
            let snapshotAt = Date()
            providerLogger.notice(
                "viewport_runtime phase=realitykit_provider_load_complete teardown_ms=\(Int(clearedAt.timeIntervalSince(loadStart) * 1000), privacy: .public) import_ms=\(Int(importedAt.timeIntervalSince(clearedAt) * 1000), privacy: .public) mapping_ms=\(Int(mappedAt.timeIntervalSince(mappingStart) * 1000), privacy: .public) visibility_ms=\(Int(visibilityAt.timeIntervalSince(mappedAt) * 1000), privacy: .public) bounds_ms=\(Int(boundsAt.timeIntervalSince(visibilityAt) * 1000), privacy: .public) snapshot_ms=\(Int(snapshotAt.timeIntervalSince(boundsAt) * 1000), privacy: .public) total_ms=\(Int(snapshotAt.timeIntervalSince(loadStart) * 1000), privacy: .public) url=\(url.path, privacy: .public)"
            )
        } catch {
            // Discard if generation changed
            guard currentLoadGeneration == generation, activeViewportID == viewportID else {
                providerLogger.notice(
                    "viewport_runtime phase=realitykit_provider_load_discarded reason=stale_error url=\(url.path, privacy: .public) viewport=\(viewportID.uuidString, privacy: .public) generation=\(generation, privacy: .public) current_generation=\(self.currentLoadGeneration, privacy: .public)"
                )
                throw CancellationError()
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
        providerLogger.notice(
            "viewport_runtime phase=realitykit_entity_load_started url=\(url.path, privacy: .public)"
        )
        let loaderTask = Task(priority: .userInitiated) { () async throws -> Entity in
            providerLogger.notice(
                "viewport_runtime phase=realitykit_entity_contents_of_started url=\(url.path, privacy: .public)"
            )
            return try await Entity(contentsOf: url)
        }
        do {
            let entity = try await loaderTask.value
            providerLogger.notice(
                "viewport_runtime phase=realitykit_entity_contents_of elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) url=\(url.path, privacy: .public)"
            )
            return entity
        } catch is CancellationError {
            providerLogger.notice(
                "viewport_runtime phase=realitykit_entity_load_cancelled elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) url=\(url.path, privacy: .public)"
            )
            loaderTask.cancel()
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            providerLogger.error(
                "viewport_runtime phase=realitykit_entity_load_failed elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) url=\(url.path, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
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
        refreshPrimPathMapping(root: entity)
        applyVisibilityProjection()
        restoreExternallySuppliedSceneBounds()
        emitDiscreteSnapshotIfNeeded()
    }

    public func setHiddenPrimPaths(_ paths: Set<String>) {
        let normalized = Set(
            paths
                .map(normalizePrimPath(_:))
                .filter { !$0.isEmpty }
        )
        guard hiddenPrimPaths != normalized || modelComponentPrimPaths.isEmpty else { return }
        hiddenPrimPaths = normalized
        applyVisibilityProjection()
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

    /// Accept host-provided authored USD bounds before RealityKit has imported the model.
    ///
    /// `sceneBounds` is consumed by RealityKit camera/grid code, so it is stored in
    /// RealityKit's meter-space coordinates. Keep authored `metersPerUnit` metadata
    /// separate for inspector/unit display.
    public func setExternalSceneBounds(_ bounds: SceneBounds) {
        let convertedBounds = convertAuthoredBoundsToRealityKitMeters(bounds)
        externallySuppliedSceneBounds = convertedBounds?.isFrameable == true ? convertedBounds : nil
        guard sceneBounds != (convertedBounds ?? SceneBounds()) else { return }
        sceneBounds = convertedBounds ?? SceneBounds()
        emitDiscreteSnapshotIfNeeded()
    }
    
    /// Clear the current model
    public func teardown() {
        activeViewportID = nil
        currentLoadGeneration &+= 1
        teardownState()
    }

    public func teardown(viewportID: UUID) {
        guard activeViewportID == viewportID else { return }
        currentLoadGeneration &+= 1
        teardownState()
    }

    private func teardownState() {
        stopEmbeddedAnimations()
        modelEntity = nil
        currentFileURL = nil
        isLoaded = false
        sceneBounds = externallySuppliedSceneBounds ?? SceneBounds()
        selectedPrimPath = nil
        loadError = nil
        primPathToEntityID.removeAll()
        entityIDToPrimPath.removeAll()
        projectedHiddenEntityIDs.removeAll()
        modelComponentPrimPaths.removeAll()
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

    // Weak reference captured once in RealityView make: so gesture handlers can
    // write directly to the entity without going through the update: closure.
    private weak var cameraEntity: Entity?

    internal func setCameraEntity(_ entity: Entity?) {
        cameraEntity = entity
    }

    /// Apply an ArcballCameraState directly to the camera entity.
    /// Called from gesture/scroll handlers (outside SwiftUI view-body scope per
    /// WWDC 2025 session 274) so the entity moves at input time, not render time.
    internal func applyCameraTransform(_ state: ArcballCameraState) {
        let transform = state.transform
        cameraEntity?.transform.matrix = transform
        cameraWorldTransform = transform
        cameraFocus = state.focus
        cameraRotation = state.quaternion
        cameraDistance = state.distance
    }

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

    public var needsCameraRecentering: Bool {
        let defaultFocus = sceneBounds.isFrameable ? sceneBounds.center : .zero
        let defaultDistance = sceneBounds.isFrameable
            ? ViewportTuning.defaultCameraDistance(
                sceneBounds: sceneBounds,
                // Provider `sceneBounds` are already RealityKit meters.
                metersPerUnit: 1.0
            )
            : 5.0
        let focusDelta = simd_length(cameraFocus - defaultFocus)
        let distanceDelta = Swift.abs(cameraDistance - defaultDistance)
        let distanceEpsilon = Swift.max(
            Self.minimumCameraDistanceEpsilon,
            defaultDistance * Self.cameraDistanceEpsilonRatio
        )
        return focusDelta > Self.cameraFocusEpsilon || distanceDelta > distanceEpsilon
    }

    internal func updateCameraState(
        focus: SIMD3<Float>,
        rotation: simd_quatf,
        distance: Float
    ) {
        self.cameraFocus = focus
        self.cameraRotation = rotation
        self.cameraDistance = distance
    }
    
    internal func restoreExternallySuppliedSceneBounds() {
        if let authoredBounds = externallySuppliedSceneBounds, authoredBounds.isFrameable {
            self.sceneBounds = authoredBounds
        } else {
            providerLogger.error(
                "No authored scene bounds supplied; clearing scene bounds instead of using RealityKit visual bounds."
            )
            self.sceneBounds = SceneBounds()
        }
        providerLogger.notice(
            "viewport_runtime phase=authored_scene_bounds_restored frameable=\(self.sceneBounds.isFrameable, privacy: .public)"
        )
        emitDiscreteSnapshotIfNeeded()
    }

    private func convertAuthoredBoundsToRealityKitMeters(_ bounds: SceneBounds) -> SceneBounds? {
        guard bounds.isFrameable else { return nil }
        let scale = Float(metersPerUnit > 0 ? metersPerUnit : 1.0)
        return SceneBounds(min: bounds.min * scale, max: bounds.max * scale)
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

private extension String {
    var lastPrimPathComponent: String {
        split(separator: "/").last.map(String.init) ?? self
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
    internal func refreshPrimPathMapping(root: Entity) {
        let start = Date()
        let mapping = buildPrimPathMapping(root: root)
        primPathToEntityID = mapping.primPathToEntityID
        entityIDToPrimPath = mapping.entityIDToPrimPath

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

        for shiftedPath in droppedLeadingSegmentCandidates(for: normalized) {
            if let direct = entity(for: shiftedPath) {
                return direct
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

        if let ancestorPath = nearestAncestorMappedPath(for: normalized),
           let ancestor = entity(for: ancestorPath) {
            return ancestor
        }

        for shiftedPath in droppedLeadingSegmentCandidates(for: normalized) {
            if let ancestorPath = nearestAncestorMappedPath(for: shiftedPath),
               let ancestor = entity(for: ancestorPath) {
                return ancestor
            }
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

    private func applyVisibilityProjection() {
        guard let root = rootEntity ?? modelEntity else {
            projectedHiddenEntityIDs.removeAll()
            return
        }

        for entityID in projectedHiddenEntityIDs {
            if let entity = findEntity(byID: entityID, in: root) {
                entity.isEnabled = true
            }
        }
        projectedHiddenEntityIDs.removeAll()

        guard let scene = root.scene, let modelEntity else {
            providerLogger.notice(
                "viewport_runtime phase=realitykit_visibility_projection hidden_paths=\(self.hiddenPrimPaths.count, privacy: .public) projected_entities=0 unresolved_paths=0 unsupported_paths=\(self.hiddenPrimPaths.count, privacy: .public) renderable_entities=0"
            )
            return
        }

        let renderableEntities = scene.performQuery(renderableEntityQuery).filter { entity in
            isDescendantOrSelf(entity, of: modelEntity)
        }
        let mappedRenderableEntities: [(entityID: Entity.ID, primPath: String)] = renderableEntities.compactMap { entity in
            guard let primPath = nearestMappedPrimPath(from: entity) else { return nil }
            return (entity.id, primPath)
        }

        let newRenderablePrimPaths = Set(mappedRenderableEntities.map(\.primPath))
        if newRenderablePrimPaths != modelComponentPrimPaths {
            modelComponentPrimPaths = newRenderablePrimPaths
        }

        guard hiddenPrimPaths.isEmpty == false else {
            providerLogger.notice(
                "viewport_runtime phase=realitykit_visibility_projection hidden_paths=0 projected_entities=0 unresolved_paths=0 unsupported_paths=0 renderable_entities=\(mappedRenderableEntities.count, privacy: .public)"
            )
            return
        }

        var nextProjectedEntityIDs: Set<Entity.ID> = []
        var unresolvedPaths = 0
        var unsupportedPaths = 0

        for hiddenPath in hiddenPrimPaths {
            let matchingRenderableEntityIDs = mappedRenderableEntities.compactMap { entry -> Entity.ID? in
                let mappedPath = entry.primPath
                guard isRenderablePath(mappedPath, toggleableFrom: hiddenPath) else {
                    return nil
                }
                return entry.entityID
            }

            if matchingRenderableEntityIDs.isEmpty {
                if primPathToEntityID.keys.contains(where: { mappedPath in
                    isRenderablePath(mappedPath, toggleableFrom: hiddenPath)
                }) {
                    unsupportedPaths += 1
                } else {
                    unresolvedPaths += 1
                }
                continue
            }
            nextProjectedEntityIDs.formUnion(matchingRenderableEntityIDs)
        }

        for entityID in nextProjectedEntityIDs {
            if let entity = findEntity(byID: entityID, in: root) {
                entity.isEnabled = false
            }
        }
        projectedHiddenEntityIDs = nextProjectedEntityIDs

        providerLogger.notice(
            "viewport_runtime phase=realitykit_visibility_projection hidden_paths=\(self.hiddenPrimPaths.count, privacy: .public) projected_entities=\(self.projectedHiddenEntityIDs.count, privacy: .public) unresolved_paths=\(unresolvedPaths, privacy: .public) unsupported_paths=\(unsupportedPaths, privacy: .public) renderable_entities=\(mappedRenderableEntities.count, privacy: .public)"
        )
    }

    private func isDescendantOrSelf(_ entity: Entity, of ancestor: Entity) -> Bool {
        if entity.id == ancestor.id { return true }
        var current: Entity? = entity.parent
        while let unwrapped = current {
            if unwrapped.id == ancestor.id {
                return true
            }
            current = unwrapped.parent
        }
        return false
    }

    private func isRenderablePath(_ renderablePath: String, toggleableFrom hiddenPath: String) -> Bool {
        renderablePath == hiddenPath
            || renderablePath.hasPrefix(hiddenPath + "/")
            || renderablePath.lastPrimPathComponent == hiddenPath.lastPrimPathComponent
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
