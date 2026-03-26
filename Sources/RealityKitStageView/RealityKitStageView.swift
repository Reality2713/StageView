import ComposableArchitecture
import ImageIO
import OSLog
import RealityKit
import SwiftUI
import simd

#if os(macOS)
	import AppKit
	private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
	import UIKit
	private typealias PlatformColor = UIColor
#endif

private let logger = Logger(
	subsystem: "RealityKitStageView",
	category: "Viewport"
)
private let preflightRealityKitAnimationTimeNotification = Notification.Name(
	"preflight.realitykit.animation.time"
)
private let preflightRealityKitAnimationPlaybackNotification =
	Notification.Name("preflight.realitykit.animation.playback")

/// Stores a PostProcessOutlineEffect across SwiftUI render cycles without
/// requiring @available on the view struct itself.
private final class OutlineEffectBox: @unchecked Sendable {
	var effect: Any? = nil  // PostProcessOutlineEffect when available
}

public struct RealityKitStageView: View {
	@Environment(\.colorScheme) private var colorScheme
	let runtime: RealityKitProvider
	var configuration: RealityKitConfiguration
	var store: StoreOf<StageViewFeature>

	@State private var rootEntity: Entity?
	@State private var cameraState = ArcballCameraState()
	@State private var selectionHighlightEntity: Entity?
	@State private var outlinedEntityIDs: Set<Entity.ID> = []
	@State private var viewportInstanceID = UUID()
	@State private var gridEntity: Entity?
	/// Stable box holding the post-process outline effect (macOS 26+).
	@State private var outlineBox = OutlineEffectBox()
	/// Incremented to force a RealityView update cycle when outline state changes.
	@State private var outlineGeneration = 0
	
	// Grid throttling: track last update time and bounds to avoid excessive refreshes
	@State private var lastGridUpdateTime: Date = Date.distantPast
	@State private var lastGridBoundsExtent: Double = 0
	private static let gridUpdateInterval: TimeInterval = 0.5 // Max 2 updates per second
	private static let gridBoundsThreshold: Double = 0.05 // 5% change threshold

	/// Looked up by name from rootEntity — always available after makeSceneRoot().
	private var iblEntity: Entity? { rootEntity?.findEntity(named: "ImageBasedLight") }
	private var skyboxEntity: Entity? { rootEntity?.findEntity(named: "SkyboxSphere") }

	private var environmentRadius: Double {
		let extent = Double(runtime.sceneBounds.maxExtent)
		return Swift.max(1000.0, extent * 10.0)
	}

	public init(
		provider: RealityKitProvider,
		store: StoreOf<StageViewFeature>,
		configuration: RealityKitConfiguration = RealityKitConfiguration()
	) {
		self.runtime = provider
		self.configuration = configuration
		self.store = store
	}

	public var body: some View {
		interactiveViewport
	}

	@ViewBuilder
	private var taskBoundViewport: some View {
		viewportStack
			.task {
				for await notification in NotificationCenter.default.notifications(
					named: preflightRealityKitAnimationPlaybackNotification
				) {
					guard let userInfo = notification.userInfo,
						let isPlaying = userInfo["isPlaying"] as? Bool
					else { continue }
					await MainActor.run {
						runtime.setEmbeddedAnimationPlayback(isPlaying: isPlaying)
					}
				}
			}
			.task {
				for await notification in NotificationCenter.default.notifications(
					named: preflightRealityKitAnimationTimeNotification
				) {
					guard let userInfo = notification.userInfo,
						let seconds = userInfo["seconds"] as? Double
					else { continue }
					await MainActor.run {
						runtime.scrubEmbeddedAnimation(to: seconds)
					}
				}
			}
			.task(id: loadTaskID) {
				await handleLoadRequest()
			}
	}

	@ViewBuilder
	private var observedViewport: some View {
		observedViewportMetadata
	}

	@ViewBuilder
	private var observedViewportLifecycle: some View {
		taskBoundViewport
			.onAppear {
				runtime.activateViewport(viewportInstanceID)
				logger.debug(
					"RealityKit viewport appeared: \(self.viewportInstanceID.uuidString, privacy: .public)"
				)
				store.send(.viewportAppeared)
			}
			.onDisappear {
				runtime.deactivateViewport(viewportInstanceID)
				logger.debug(
					"RealityKit viewport disappeared: \(self.viewportInstanceID.uuidString, privacy: .public)"
				)
			}
			.onChange(of: store.selectedPrimPath) { _, newPath in
				Task { @MainActor in
					runtime.setSelection(newPath)
				}
			}
			.onChange(of: store.cameraResetRequestID) { _, requestID in
				guard requestID != nil else { return }
				Task { @MainActor in
					runtime.resetCamera()
				}
			}
			.onChange(of: runtime.modelEntity.map { ObjectIdentifier($0) }) {
				_,
				newId in
				if let entity = runtime.modelEntity, newId != nil {
					loadModel(entity)
				}
			}
				.onChange(of: runtime.selectionGeneration) { _, _ in
				updateSelectionHighlight(for: runtime.selectedPrimPath)
			}
	}

	/// Combined task ID: fires when the environment request changes AND rootEntity exists.
	/// rootEntity is @State — SwiftUI re-evaluates the body when it transitions from nil
	/// to a value, causing this ID to change from nil → UUID string → task fires.
	private var environmentTaskID: String? {
		guard let requestID = store.environmentRequestID, rootEntity != nil else { return nil }
		return requestID.uuidString
	}

	/// Combined task ID: fires only after a load request exists and the viewport
	/// has both mounted its scene root and become active.
	private var loadTaskID: String? {
		guard store.activeLoadCommand != nil,
			rootEntity != nil,
			runtime.isActiveViewport(viewportInstanceID)
		else { return nil }
		return store.loadRequestID.uuidString
	}

	@ViewBuilder
	private var observedViewportEnvironment: some View {
		observedViewportLifecycle
			.task(id: environmentTaskID) {
				guard environmentTaskID != nil else { return }
				await updateEnvironment(store.environmentURL)
			}
			.onChange(of: configuration.showEnvironmentBackground) { _, newValue in
				skyboxEntity?.isEnabled = newValue
			}
			.onChange(of: configuration.environmentExposure) { _, newValue in
				updateIBLExposure(newValue)
			}
			.onChange(of: configuration.environmentRotation) { _, newValue in
				updateIBLRotation(newValue)
			}
	}

	@ViewBuilder
	private var observedViewportMetadata: some View {
		observedViewportEnvironment
			.onChange(of: configuration.showGrid) { _, _ in
				refreshGrid()
			}
			.onChange(of: configuration.metersPerUnit) { _, newValue in
				let safeMetersPerUnit = newValue > 0 ? newValue : 1.0
				runtime.updateSceneMetadata(
					metersPerUnit: safeMetersPerUnit,
					isZUp: configuration.isZUp
				)
				refreshGrid()
				updateCamera(state: cameraState)
			}
			.onChange(of: configuration.isZUp) { _, newValue in
				runtime.updateSceneMetadata(
					metersPerUnit: configuration.metersPerUnit,
					isZUp: newValue
				)
				refreshGrid()
			}
			.onChange(of: runtime.sceneBounds) { _, newBounds in
				// Throttle grid updates based on time and significant bounds changes
				let now = Date()
				let timeSinceLastUpdate = now.timeIntervalSince(lastGridUpdateTime)
				let newExtent = Double(newBounds.maxExtent)
				let extentDelta = abs(newExtent - lastGridBoundsExtent)
				let extentChangeRatio = lastGridBoundsExtent > 0 ? extentDelta / lastGridBoundsExtent : 1.0
				
				// Update if: enough time passed OR significant bounds change
				if timeSinceLastUpdate >= Self.gridUpdateInterval || extentChangeRatio >= Self.gridBoundsThreshold {
					lastGridUpdateTime = now
					lastGridBoundsExtent = newExtent
					refreshGrid()
				}
			}
			.onChange(of: colorScheme) { _, _ in
				refreshGrid()
			}
			.onChange(of: configuration.gridMinorColor) { _, _ in
				refreshGrid()
			}
			.onChange(of: configuration.gridMajorColor) { _, _ in
				refreshGrid()
			}
			.onChange(of: cameraState) { _, newState in
				runtime.updateCameraState(
					rotation: newState.quaternion,
					distance: newState.distance
				)
				runtime.cameraWorldTransform = newState.transform
			}
	}

	@ViewBuilder
	private var interactiveViewport: some View {
		observedViewport
			.withLiveTransform(store: store, provider: runtime)
			.withRuntimeBlendShapes(store: store, provider: runtime)
			#if os(macOS)
				.modifier(
					ArcballCameraControls(
						state: $cameraState,
						sceneBounds: runtime.sceneBounds,
						metersPerUnit: configuration.metersPerUnit,
						maxDistance: Float(environmentRadius * 0.9),
						navigationMapping: store.navigationMapping,
						onPick: macOSPickHandler
					)
				)
			#else
				.gesture(selectionGesture)
				.gesture(clearSelectionGesture)
			#endif
	}

	@ViewBuilder
	private var viewportStack: some View {
		ZStack {
			realityViewLayer
			overlays
		}
	}

	@ViewBuilder
	private var realityViewLayer: some View {
		RealityView { content in
			logger.debug(
				"RealityView content mounted for viewport \(self.viewportInstanceID.uuidString, privacy: .public)"
			)
			let root = makeSceneRoot()
			content.add(root)
			self.rootEntity = root
			runtime.updateRootEntity(root, viewportID: viewportInstanceID)

			if runtime.isActiveViewport(viewportInstanceID), let entity = runtime.modelEntity {
				loadModel(entity)
			}
		} update: { content in
			syncIBLState()
			updateCamera(state: cameraState)
			processRuntimeViewRequests()
			if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
				if var effect = outlineBox.effect as? PostProcessOutlineEffect {
					if let camera = rootEntity?.findEntity(named: "MainCamera") {
						let noRef: Entity? = nil
						let cameraWorldTransform = camera.transformMatrix(relativeTo: noRef)
						effect.setViewMatrix(cameraWorldTransform.inverse)
						outlineBox.effect = effect
					}
					content.renderingEffects.customPostProcessing = .effect(effect)
				} else {
					content.renderingEffects.customPostProcessing = .none
				}
			}
			_ = outlineGeneration  // establish dependency so RealityView re-runs on selection change
		}
		.overlay {
			if let error = runtime.loadError {
				errorOverlay(error)
			}
		}
	}

	private var selectionGesture: some Gesture {
		SpatialTapGesture()
			.targetedToAnyEntity()
			.onEnded { value in
				let path = runtime.preferredPickPrimPath(from: value.entity)
				runtime.userDidPick(path)
				store.send(.entityPicked(path))
			}
	}

	private var clearSelectionGesture: some Gesture {
		SpatialTapGesture()
			.onEnded { _ in
				runtime.userDidPick(nil)
				store.send(.entityPicked(nil))
			}
	}

	// MARK: - macOS Picking

	#if os(macOS)
	/// Closure passed to ArcballCameraControls for NSEvent-based click detection.
	private var macOSPickHandler: (CGPoint, CGSize) -> Void {
		let r = runtime
		let s = store
		return { location, size in
			Task { @MainActor in Self.macOSPick(at: location, in: size, runtime: r, store: s) }
		}
	}

	@MainActor
	private static func macOSPick(
		at location: CGPoint,
		in size: CGSize,
		runtime: RealityKitProvider,
		store: StoreOf<StageViewFeature>
	) {
		logger.debug("macOSPick called at \(location.x, privacy: .public),\(location.y, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
		guard size.width > 0, size.height > 0 else {
			logger.debug("macOSPick: invalid size, returning")
			return
		}
		guard let scene = runtime.rootEntity?.scene else {
			logger.debug("macOSPick: no scene (rootEntity=\(runtime.rootEntity?.name ?? "nil", privacy: .public))")
			return
		}

		let camera = runtime.rootEntity?.findEntity(named: "MainCamera")
		let fovDegrees = Float(camera?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 60)
		let tanHalfFov = tan(fovDegrees * (.pi / 180) / 2)
		let aspect = Float(size.width / size.height)

		// location is y-down (0=top). Convert to NDC: x∈[-1,1], y∈[-1,1] y-up.
		let ndcX = Float(location.x / size.width) * 2 - 1
		let ndcY = 1 - Float(location.y / size.height) * 2

		// Ray direction in camera local space (camera looks down -Z).
		let localDir = SIMD3<Float>(ndcX * tanHalfFov * aspect, ndcY * tanHalfFov, -1)

		// Transform to world space using the camera's world transform columns.
		let t = runtime.cameraWorldTransform
		let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
		let worldDir = simd_normalize(SIMD3<Float>(
			t.columns.0.x * localDir.x + t.columns.1.x * localDir.y + t.columns.2.x * localDir.z,
			t.columns.0.y * localDir.x + t.columns.1.y * localDir.y + t.columns.2.y * localDir.z,
			t.columns.0.z * localDir.x + t.columns.1.z * localDir.y + t.columns.2.z * localDir.z
		))

		logger.debug("macOSPick raycast: camPos=\(camPos.x, privacy: .public),\(camPos.y, privacy: .public),\(camPos.z, privacy: .public) dir=\(worldDir.x, privacy: .public),\(worldDir.y, privacy: .public),\(worldDir.z, privacy: .public) fov=\(fovDegrees, privacy: .public)° ndc=\(ndcX, privacy: .public),\(ndcY, privacy: .public)")

		let hits = scene.raycast(
			origin: camPos, direction: worldDir, length: 100_000,
			query: .all, mask: .all, relativeTo: nil
		)

		logger.debug("macOSPick raycast hit count: \(hits.count, privacy: .public)")
		if let hit = hits.first {
			let path = runtime.preferredPickPrimPath(from: hits.map(\.entity))
			logger.debug("macOSPick hit entity='\(hit.entity.name, privacy: .public)' path=\(path ?? "nil", privacy: .public)")
			runtime.userDidPick(path)
			store.send(.entityPicked(path))
		} else {
			logger.debug("macOSPick no hit — clearing selection")
			runtime.userDidPick(nil)
			store.send(.entityPicked(nil))
		}
	}
	#endif

	private func handleLoadRequest() async {
		guard let command = store.activeLoadCommand else {
			if store.modelURL == nil {
				logger.debug(
					"Tearing down viewport \(self.viewportInstanceID.uuidString, privacy: .public) because modelURL is nil"
				)
				await MainActor.run {
					runtime.teardown(viewportID: viewportInstanceID)
				}
			}
			return
		}

		guard runtime.isActiveViewport(viewportInstanceID) else { return }

		logger.info(
			"Viewport \(self.viewportInstanceID.uuidString, privacy: .public) loading model: \(command.url.lastPathComponent, privacy: .public) [\(String(describing: command.mode), privacy: .public)]"
		)
		runtime.setPreserveCameraOnNextLoad(command.preserveCamera)
		do {
			switch command.mode {
			case .fullLoad:
				try await runtime.load(command.url, viewportID: viewportInstanceID)
			case .refresh:
				try await runtime.load(command.url, viewportID: viewportInstanceID)
			}
			guard runtime.isActiveViewport(viewportInstanceID) else { return }
			_ = await MainActor.run { store.send(.loadCommandCompleted(command.id)) }
			logger.info("Model loaded successfully")
		} catch {
			guard runtime.isActiveViewport(viewportInstanceID) else { return }
			_ = await MainActor.run {
				store.send(.loadCommandFailed(command.id, error.localizedDescription))
			}
			logger.error(
				"Model load failed: \(error.localizedDescription, privacy: .public)"
			)
		}
	}

	@ViewBuilder
	private var overlays: some View {
		GeometryReader { proxy in
			VStack {
				scaleIndicator(viewportWidth: proxy.size.width)
				Spacer()
				HStack {
					orientationGizmo
					Spacer()
				}
			}
			.padding(12)
			.allowsHitTesting(false)
		}
	}

	@ViewBuilder
	private func scaleIndicator(viewportWidth: CGFloat) -> some View {
		let referenceDepthMeters = Double(runtime.cameraDistance)
		if referenceDepthMeters.isFinite, referenceDepthMeters > 0 {
			ScaleIndicatorView(
				referenceDepthMeters: referenceDepthMeters,
				viewportWidthPoints: Double(max(1, viewportWidth)),
				horizontalFOVDegrees: 60
			)
		}
	}

	@ViewBuilder
	private var orientationGizmo: some View {
		if cameraState.quaternion.vector.isFinite {
			OrientationGizmoView(
				cameraRotation: cameraState.quaternion,
				isZUp: runtime.isZUp
			)
		}
	}

	@ViewBuilder
	private func errorOverlay(_ error: String) -> some View {
		VStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.largeTitle)
				.foregroundStyle(.yellow)
			Text("Load Failed")
				.font(.headline)
			Text(error)
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.padding(24)
		.background(.regularMaterial)
		.cornerRadius(12)
	}

	@MainActor
	private func makeSceneRoot() -> Entity {
		SelectionOutlineSystem.registerSystem()
		runtime.updateSceneMetadata(
			metersPerUnit: configuration.metersPerUnit,
			isZUp: configuration.isZUp
		)

		let root = Entity()
		root.name = "SceneRoot"

		let modelAnchor = Entity()
		modelAnchor.name = "ModelAnchor"
		root.addChild(modelAnchor)

		let light = DirectionalLight()
		light.name = "KeyLight"
		light.light.intensity = 2000
		light.light.color = .white
		light.look(at: .zero, from: [2, 4, 5], relativeTo: nil)
		root.addChild(light)

		let fillLight = DirectionalLight()
		fillLight.name = "FillLight"
		fillLight.light.intensity = 1000
		fillLight.look(at: .zero, from: [-2, 2, -3], relativeTo: nil)
		root.addChild(fillLight)

		if configuration.showGrid {
			Task {
				await loadProceduralGrid(into: root)
			}
		}

		let camera = PerspectiveCamera()
		camera.name = "MainCamera"
		if var component = camera.components[PerspectiveCameraComponent.self] {
			let clip = ViewportTuning.clippingRange(
				distance: cameraState.distance,
				sceneBounds: runtime.sceneBounds,
				metersPerUnit: configuration.metersPerUnit,
				environmentRadius: Float(environmentRadius)
			)
			component.near = clip.near
			component.far = clip.far
			camera.components.set(component)
		}
		camera.position = [0, 1, 2]
		camera.look(at: .zero, from: [0, 1, 2], relativeTo: nil)
		root.addChild(camera)

		let ibl = Entity()
		ibl.name = "ImageBasedLight"
		root.addChild(ibl)

		// Skybox sphere — created once, texture updated when environment changes.
		// Visibility controlled via isEnabled (synchronous, no race).
		// Tone mapping is left ON (default) so the HDR panorama is compressed
		// into displayable range the same way RealityKit tone-maps lit objects,
		// producing consistent exposure between background and foreground — and
		// closer parity with Hydra Storm, which also tone-maps its dome output.
		let skybox = Entity()
		skybox.name = "SkyboxSphere"
		skybox.components.set(ModelComponent(
			mesh: .generateSphere(radius: Float(environmentRadius)),
			materials: [UnlitMaterial()]
		))
		// X-flip inverts winding order so inside faces become front-facing.
		skybox.scale = .init(x: -1, y: 1, z: 1)
		skybox.isEnabled = false
		root.addChild(skybox)

		return root
	}

	@MainActor
	private func loadModel(_ entity: Entity) {
		entity.name = "LoadedModel"
		let preserveCamera = runtime.consumePreserveCameraOnNextLoad()

		let anchor = rootEntity?.findEntity(named: "ModelAnchor")
		anchor?.children.first(where: { $0.name == "LoadedModel" })?
			.removeFromParent()

		if let modelAnchor = anchor {
			modelAnchor.addChild(entity)
			runtime.startEmbeddedAnimationsIfAvailable(autoPlay: false)

			prepareForPicking(entity)
			runtime.updateSceneBoundsFromAttachedEntity(entity)
			refreshGrid()

			if !preserveCamera, rootEntity?.findEntity(named: "MainCamera") != nil {
				let bounds = runtime.sceneBounds
				let distance = ViewportTuning.defaultCameraDistance(
					sceneBounds: bounds,
					metersPerUnit: configuration.metersPerUnit
				)

				var newState = cameraState
				newState.focus = bounds.center
				newState.distance = distance
				newState.rotation = SIMD3<Float>(-20 * .pi / 180, 0, 0)
				cameraState = newState
			}

			applyIBLReceiver(to: entity)
		}
	}

	private func prepareForPicking(_ entity: Entity) {
		markInputTargetsRecursively(entity)
		// Generate collision shapes once for the full subtree.
		entity.generateCollisionShapes(recursive: true)
	}

	private func markInputTargetsRecursively(_ entity: Entity) {
		entity.components.set(InputTargetComponent(allowedInputTypes: .all))
		for child in entity.children {
			markInputTargetsRecursively(child)
		}
	}

	@MainActor
	private func updateCamera(state: ArcballCameraState) {
		guard let camera = rootEntity?.findEntity(named: "MainCamera") else {
			return
		}
		if var component = camera.components[PerspectiveCameraComponent.self] {
			let clip = ViewportTuning.clippingRange(
				distance: state.distance,
				sceneBounds: runtime.sceneBounds,
				metersPerUnit: configuration.metersPerUnit,
				environmentRadius: Float(environmentRadius)
			)
			if Swift.abs(component.near - clip.near) > 0.0001
				|| Swift.abs(component.far - clip.far) > 0.01
			{
				component.near = clip.near
				component.far = clip.far
				camera.components.set(component)
			}
		}
		camera.transform.matrix = state.transform
	}

	@MainActor
	private func refreshGrid() {
		guard let root = rootEntity else { return }

		if !configuration.showGrid {
			gridEntity?.removeFromParent()
			gridEntity = nil
			return
		}

		// If the grid entity already exists, just update its parameters.
		if let existing = gridEntity {
			RealityKitGrid.updateProceduralGrid(
				entity: existing,
				metersPerUnit: configuration.metersPerUnit,
				worldExtent: Double(runtime.sceneBounds.maxExtent),
				isZUp: configuration.isZUp,
				appearance: colorScheme == .light ? .light : .dark,
				minorColorOverride: configuration.gridMinorColor,
				majorColorOverride: configuration.gridMajorColor
			)
			// Re-parent if needed (e.g. after toggling showGrid off then on).
			if existing.parent == nil {
				root.addChild(existing)
			}
			return
		}

		// First time — async load.
		Task {
			await loadProceduralGrid(into: root)
		}
	}

	@MainActor
	private func loadProceduralGrid(into root: Entity) async {
		// Remove any stale grid.
		root.findEntity(named: "ReferenceGrid")?.removeFromParent()

		guard
			let grid = await RealityKitGrid.createProceduralGridEntity(
				metersPerUnit: configuration.metersPerUnit,
				worldExtent: Double(runtime.sceneBounds.maxExtent),
				isZUp: configuration.isZUp,
				appearance: colorScheme == .light ? .light : .dark,
				minorColorOverride: configuration.gridMinorColor,
				majorColorOverride: configuration.gridMajorColor
			)
		else { return }

		self.gridEntity = grid
		root.addChild(grid)
	}

	private func processRuntimeViewRequests() {
		let shouldResetCamera = runtime._resetCameraRequested
		let shouldFrameSelection = runtime._frameSelectionRequested
		guard shouldResetCamera || shouldFrameSelection else { return }

		Task { @MainActor in
			if shouldResetCamera {
				runtime._resetCameraRequested = false
				resetCameraInternal()
			}
			if shouldFrameSelection {
				runtime._frameSelectionRequested = false
			}
		}
	}

	@MainActor
	private func resetCameraInternal() {
		cameraState = ArcballCameraState(
			focus: .zero,
			rotation: SIMD3<Float>(-20 * .pi / 180, 0, 0),
			distance: 5.0
		)
	}

	@MainActor
	private func updateSelectionHighlight(for path: String?) {
		for id in outlinedEntityIDs {
			if let entity = rootEntity?.scene?.findEntity(id: id) {
				entity.components.remove(SelectionOutlineComponent.self)
				if let outlineChild = entity.children.first(where: {
					$0.name == SelectionOutlineSystem.outlineEntityName
				}) {
					outlineChild.removeFromParent()
				}
			}
		}
		outlinedEntityIDs.removeAll()

		selectionHighlightEntity?.removeFromParent()
		selectionHighlightEntity = nil

		if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
			clearPostProcessOutline()
		}

		guard let path = path, !path.isEmpty else { return }

		guard let target = runtime.selectionEntity(for: path) else { return }
		logger.debug(
			"Selection highlight path=\(path, privacy: .public) target='\(target.name, privacy: .public)' directModel=\(target.components.has(ModelComponent.self), privacy: .public) subtreeModels=\(countModelEntities(in: target), privacy: .public)"
		)

		switch configuration.selectionHighlightStyle {
		case .none:
			return
		case .outline:
			applyOutline(to: target)
		case .boundingBox:
			applyBoundingBox(to: target)
		case .postProcessOutline:
			if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
				applyPostProcessOutline(to: target)
			} else {
				applyOutline(to: target)
			}
		}
	}

	@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
	@MainActor
	private func applyPostProcessOutline(to entity: Entity) {
		var effect: PostProcessOutlineEffect
		if let existing = outlineBox.effect as? PostProcessOutlineEffect {
			effect = existing
		} else {
			effect = PostProcessOutlineEffect(
				color: configuration.outlineConfiguration.color,
				radius: 2
			)
		}
		effect.setSelection(entity)
		outlineBox.effect = effect
		outlineGeneration += 1
	}

	@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
	@MainActor
	private func clearPostProcessOutline() {
		if var effect = outlineBox.effect as? PostProcessOutlineEffect {
			effect.setSelection(nil)
			outlineBox.effect = effect
			outlineGeneration += 1
		}
	}

	@MainActor
	private func countModelEntities(in entity: Entity) -> Int {
		var count = entity.components.has(ModelComponent.self) ? 1 : 0
		for child in entity.children {
			count += countModelEntities(in: child)
		}
		return count
	}


	@MainActor
	private func applyOutline(to entity: Entity) {
		if entity.name == SelectionOutlineSystem.outlineEntityName { return }

		if entity.components.has(ModelComponent.self) {
			entity.components.set(
				SelectionOutlineComponent(
					configuration: configuration.outlineConfiguration
				)
			)
			outlinedEntityIDs.insert(entity.id)
		}
		for child in entity.children {
			applyOutline(to: child)
		}
	}

	@MainActor
	private func applyBoundingBox(to target: Entity) {
		guard let root = rootEntity else { return }

		let bounds = target.visualBounds(relativeTo: root)
		let extents = bounds.extents
		guard extents.isFinite else { return }

		let maxExtent = Swift.max(extents.x, Swift.max(extents.y, extents.z))
		guard maxExtent > 0.0001 else { return }

		let edgeThickness = Swift.max(0.0015, maxExtent * 0.0075)
		let halfX = Swift.max(extents.x * 0.5, edgeThickness * 0.5)
		let halfY = Swift.max(extents.y * 0.5, edgeThickness * 0.5)
		let halfZ = Swift.max(extents.z * 0.5, edgeThickness * 0.5)

		let xLength = Swift.max(extents.x, edgeThickness)
		let yLength = Swift.max(extents.y, edgeThickness)
		let zLength = Swift.max(extents.z, edgeThickness)

		var material = UnlitMaterial()
		material.color = .init(tint: selectionTintColor(alpha: 0.95))

		let xEdgeMesh = MeshResource.generateBox(
			width: xLength,
			height: edgeThickness,
			depth: edgeThickness
		)
		let yEdgeMesh = MeshResource.generateBox(
			width: edgeThickness,
			height: yLength,
			depth: edgeThickness
		)
		let zEdgeMesh = MeshResource.generateBox(
			width: edgeThickness,
			height: edgeThickness,
			depth: zLength
		)

		let cage = Entity()
		cage.name = "__selectionBounds__"
		cage.position = bounds.center

		let signs: [Float] = [-1, 1]
		for sy in signs {
			for sz in signs {
				addEdge(
					to: cage,
					mesh: xEdgeMesh,
					material: material,
					position: SIMD3<Float>(0, sy * halfY, sz * halfZ)
				)
			}
		}
		for sx in signs {
			for sz in signs {
				addEdge(
					to: cage,
					mesh: yEdgeMesh,
					material: material,
					position: SIMD3<Float>(sx * halfX, 0, sz * halfZ)
				)
			}
		}
		for sx in signs {
			for sy in signs {
				addEdge(
					to: cage,
					mesh: zEdgeMesh,
					material: material,
					position: SIMD3<Float>(sx * halfX, sy * halfY, 0)
				)
			}
		}

		root.addChild(cage)
		selectionHighlightEntity = cage
	}

	@MainActor
	private func addEdge(
		to parent: Entity,
		mesh: MeshResource,
		material: UnlitMaterial,
		position: SIMD3<Float>
	) {
		let edge = Entity()
		edge.components.set(ModelComponent(mesh: mesh, materials: [material]))
		edge.position = position
		parent.addChild(edge)
	}

	private func selectionTintColor(alpha: CGFloat) -> PlatformColor {
		let resolved = configuration.outlineConfiguration.color.resolve(
			in: EnvironmentValues()
		)
		return PlatformColor(
			red: CGFloat(resolved.red),
			green: CGFloat(resolved.green),
			blue: CGFloat(resolved.blue),
			alpha: alpha
		)
	}

	@MainActor
	private func syncIBLState() {
		updateIBLExposure(configuration.environmentExposure)
		updateIBLRotation(configuration.environmentRotation)
		updateIBLLightIntensity()
	}

	@MainActor
	private func updateEnvironment(_ url: URL?) async {
		guard let ibl = iblEntity else { return }

		// Clear existing IBL; skybox stays (just update its material).
		ibl.components.remove(ImageBasedLightComponent.self)

		guard let url = url else {
			// No environment — hide skybox, clear its texture.
			skyboxEntity?.isEnabled = false
			return
		}

		let resourceName =
			url.deletingLastPathComponent().lastPathComponent + "_"
			+ url.lastPathComponent

		let imageOptions: [String: Any] = [
			kCGImageSourceShouldAllowFloat as String: true,
			kCGImageSourceShouldCache as String: false,
		]

		guard let dataProvider = CGDataProvider(url: url as CFURL),
			let source = CGImageSourceCreateWithDataProvider(dataProvider, imageOptions as CFDictionary),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary)
		else {
			logger.error("Environment: failed to decode CGImage from \(url.lastPathComponent, privacy: .public)")
			return
		}

		// IBL lighting — uses the full HDR float image via EnvironmentResource.
		do {
			let resource = try await EnvironmentResource(equirectangular: cgImage, withName: resourceName)
			var iblComp = ImageBasedLightComponent(source: .single(resource))
			iblComp.intensityExponent = configuration.realityKitIntensityExponent
			iblComp.inheritsRotation = true
			ibl.components.set(iblComp)
			if let model = runtime.modelEntity {
				applyIBLReceiver(to: model)
			}
		} catch {
			logger.error("Environment IBL failed: \(error.localizedDescription, privacy: .public)")
		}

		// Update skybox texture on the existing sphere entity.
		if let skybox = skyboxEntity,
		   let existingModel = skybox.components[ModelComponent.self]
		{
			do {
				let texture: TextureResource
				do {
					// Use the already-decoded float CGImage and mark it as HDR so
					// the visible dome does not go through the generic file loader's
					// `.color` path, which can flatten the skybox relative to the IBL.
					texture = try await TextureResource(
						image: cgImage,
						withName: resourceName + "_skybox",
						options: .init(semantic: .hdrColor)
					)
				} catch {
					logger.warning("HDR skybox texture creation failed; falling back to file load: \(error.localizedDescription, privacy: .public)")
					texture = try await TextureResource(
						contentsOf: url,
						withName: resourceName + "_skybox",
						options: .init(semantic: .color)
					)
				}
				var material = UnlitMaterial()
				material.color = .init(texture: .init(texture))
				skybox.components.set(ModelComponent(
					mesh: existingModel.mesh,
					materials: [material]
				))
				skybox.isEnabled = configuration.showEnvironmentBackground
				logger.debug("Skybox updated: enabled=\(configuration.showEnvironmentBackground)")
			} catch {
				logger.error("Skybox texture load failed: \(error.localizedDescription, privacy: .public)")
			}
		} else {
			logger.warning("Skybox entity not found or has no ModelComponent")
		}

		// Apply all current visual state immediately — don't wait for the next
		// syncIBLState() call from the update: closure, which would cause a
		// brief flash at default exposure after every environment reload.
		updateIBLExposure(configuration.environmentExposure)
		updateIBLRotation(configuration.environmentRotation)
		updateIBLLightIntensity()
	}


	@MainActor
	private func updateIBLExposure(_ exposure: Float) {
		if let ibl = iblEntity,
			var iblComp = ibl.components[ImageBasedLightComponent.self]
		{
			iblComp.intensityExponent =
				RealityKitConfiguration.realityKitIntensityExponent(
					forHydraEV: exposure
				)
			iblComp.inheritsRotation = true
			ibl.components.set(iblComp)
		}

		if let skybox = skyboxEntity,
			let model = skybox.components[ModelComponent.self]
		{
			// Skybox brightness = 2^EV applied as a linear tint multiplier.
			// applyPostProcessToneMap: false bypasses RealityKit's tone pipeline,
			// but tint values above ~7.5 still trigger a RealityKit rendering bug
			// (visual discontinuity / artifact) even without tone mapping.
			let gain = RealityKitConfiguration.hydraLinearExposureGain(forEV: exposure)
			let tint = CGFloat(min(max(gain, 0), 7.5))

			let existingTexture = (model.materials.first as? UnlitMaterial)?.color.texture
			var material = UnlitMaterial()
			let color = PlatformColor(red: tint, green: tint, blue: tint, alpha: 1.0)
			material.color = .init(tint: color, texture: existingTexture)

			var newModel = model
			newModel.materials = [material]
			skybox.components.set(newModel)
		}
	}

	@MainActor
	private func updateIBLRotation(_ degrees: Float) {
		// RealityKit always renders in Y-up world space — it converts Z-up source
		// files on load. The IBL entity therefore lives in Y-up space regardless of
		// the source file's up-axis, so we always rotate around world Y.
		//
		// The offset compensates for RealityKit's IBL zero-meridian differing from
		// Hydra Storm's. Empirically both Y-up and Z-up scenes are consistently 270°
		// (3π/2) off without correction, so we add 3π/2.
		let radians = degrees * .pi / 180.0 + 3 * .pi / 2
		let orientation = simd_quatf(angle: radians, axis: [0, 1, 0])

		if let iblEntity {
			iblEntity.transform.rotation = orientation

			if var iblComp = iblEntity.components[ImageBasedLightComponent.self] {
				if !iblComp.inheritsRotation {
					iblComp.inheritsRotation = true
				}
				iblEntity.components.set(iblComp)
			}
		}

		if let skyboxEntity {
			// X-flip on the sphere means inside faces are front-facing, and the UV longitude
			// is mirrored such that applying the same orientation as the IBL entity produces
			// matching apparent rotation from inside the sphere.
			skyboxEntity.transform.rotation = orientation
		}
	}

	private func applyIBLReceiver(to entity: Entity) {
		guard let ibl = iblEntity else { return }
		entity.components.set(
			ImageBasedLightReceiverComponent(imageBasedLight: ibl)
		)
		for child in entity.children {
			applyIBLReceiver(to: child)
		}
	}

	@MainActor
	private func updateIBLLightIntensity() {
		guard let root = rootEntity else { return }
		let useIBL = store.environmentURL != nil
		if let key = root.findEntity(named: "KeyLight") as? DirectionalLight {
			key.light.intensity = useIBL ? 0 : 2000
		}
		if let fill = root.findEntity(named: "FillLight") as? DirectionalLight {
			fill.light.intensity = useIBL ? 0 : 1000
		}
	}

}

extension SIMD4 where Scalar == Float {
	fileprivate var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite && w.isFinite
	}
}

extension SIMD3 where Scalar == Float {
	fileprivate var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite
	}
}
