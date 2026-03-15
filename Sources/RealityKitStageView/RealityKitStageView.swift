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

public struct RealityKitStageView: View {
	@Environment(\.colorScheme) private var colorScheme
	let runtime: RealityKitProvider
	var configuration: RealityKitConfiguration
	var store: StoreOf<StageViewFeature>

	@State private var rootEntity: Entity?
	@State private var iblEntity: Entity?
	@State private var skyboxEntity: Entity?
	@State private var cameraState = ArcballCameraState()
	@State private var selectionHighlightEntity: Entity?
	@State private var outlinedEntityIDs: Set<Entity.ID> = []
	@State private var viewportInstanceID = UUID()
	@State private var gridEntity: Entity?

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
				for await snapshot in runtime.observeDiscreteState() {
					guard snapshot.isUserInteraction else { continue }
					await MainActor.run {
						_ = store.send(.entityPicked(snapshot.selectedPrimPath))
					}
				}
			}
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
			.task(id: store.loadRequestID) {
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
				logger.debug(
					"RealityKit viewport appeared: \(self.viewportInstanceID.uuidString, privacy: .public)"
				)
			}
			.onDisappear {
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
				.onChange(of: runtime.selectedPrimPath) { _, newPath in
				updateSelectionHighlight(for: newPath)
			}
	}

	/// Combined trigger: fires only when both environment request and IBL entity are ready.
	/// Using the request ID string (not UUID?) so the task doesn't fire when iblEntity is nil.
	private var environmentTaskTrigger: String? {
		guard let requestID = store.environmentRequestID, iblEntity != nil else { return nil }
		return requestID.uuidString
	}

	@ViewBuilder
	private var observedViewportEnvironment: some View {
		observedViewportLifecycle
			.task(id: environmentTaskTrigger) {
				guard environmentTaskTrigger != nil else { return }
				await updateEnvironment(store.environmentURL)
			}
			.onChange(of: configuration.showEnvironmentBackground) { _, newValue in
				skyboxEntity?.isEnabled = newValue
			}
			.onChange(of: configuration.environmentExposure) { _, _ in
				updateIBLLightIntensity()
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
			.onChange(of: runtime.sceneBounds) { _, _ in
				refreshGrid()
			}
			.onChange(of: colorScheme) { _, _ in
				refreshGrid()
			}
			.onChange(of: cameraState) { _, newState in
				runtime.updateCameraState(
					rotation: newState.quaternion,
					distance: newState.distance
				)
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
						navigationMapping: store.navigationMapping
					)
				)
			#endif
			.gesture(selectionGesture)
			.gesture(clearSelectionGesture)
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
			runtime.updateRootEntity(root)

			if let entity = runtime.modelEntity {
				loadModel(entity)
			}
		} update: { _ in
			syncIBLState()
			updateCamera(state: cameraState)
			processRuntimeViewRequests()
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
				if let path = runtime.nearestMappedPrimPath(from: value.entity) {
					runtime.userDidPick(path)
				} else {
					runtime.userDidPick(nil)
				}
			}
	}

	private var clearSelectionGesture: some Gesture {
		SpatialTapGesture()
			.onEnded { _ in
				runtime.userDidPick(nil)
			}
	}

	private func handleLoadRequest() async {
		guard let command = store.activeLoadCommand else {
			if store.modelURL == nil {
				logger.debug(
					"Tearing down viewport \(self.viewportInstanceID.uuidString, privacy: .public) because modelURL is nil"
				)
				await MainActor.run {
					runtime.teardown()
				}
			}
			return
		}

		logger.info(
			"Viewport \(self.viewportInstanceID.uuidString, privacy: .public) loading model: \(command.url.lastPathComponent, privacy: .public) [\(String(describing: command.mode), privacy: .public)]"
		)
		runtime.setPreserveCameraOnNextLoad(command.preserveCamera)
		do {
			switch command.mode {
			case .fullLoad:
				try await runtime.load(command.url)
			case .refresh:
				try await runtime.load(command.url)
			}
			_ = await MainActor.run { store.send(.loadCommandCompleted(command.id)) }
			logger.info("Model loaded successfully")
		} catch {
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
		self.iblEntity = ibl

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
			refreshGrid()

			if !preserveCamera, rootEntity?.findEntity(named: "MainCamera") != nil {
				let bounds = entity.visualBounds(relativeTo: nil)
				let center = bounds.center
				let distance = ViewportTuning.defaultCameraDistance(
					sceneBounds: runtime.sceneBounds,
					metersPerUnit: configuration.metersPerUnit
				)

				var newState = cameraState
				newState.focus = center
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
		entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
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
				appearance: colorScheme == .light ? .light : .dark
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
				appearance: colorScheme == .light ? .light : .dark
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

		guard let path = path, !path.isEmpty else { return }

		guard let target = runtime.selectionEntity(for: path) else { return }

		switch configuration.selectionHighlightStyle {
		case .none:
			return
		case .outline:
			applyOutline(to: target)
		case .boundingBox:
			applyBoundingBox(to: target)
		}
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

		ibl.components.remove(ImageBasedLightComponent.self)
		skyboxEntity?.removeFromParent()
		skyboxEntity = nil

		guard let url = url else { return }

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

		// Skybox background sphere — always created alongside IBL so the texture
		// is ready when toggled on. Visibility is controlled synchronously via
		// isEnabled (no async race). task(id:) cancels stale loads automatically.
		do {
			let texture = try TextureResource.load(
				contentsOf: url,
				withName: resourceName + "_skybox",
				options: .init(semantic: .color)
			)
			var material = UnlitMaterial()
			material.color = .init(texture: .init(texture))

			let skybox = Entity()
			skybox.name = "SkyboxSphere"
			skybox.components.set(ModelComponent(
				mesh: try Self.makeSkyboxSphere(radius: Float(environmentRadius)),
				materials: [material]
			))
			// X-flip inverts winding order so inside faces become front-facing.
			skybox.scale *= .init(x: -1, y: 1, z: 1)
			skybox.isEnabled = configuration.showEnvironmentBackground
			rootEntity?.addChild(skybox)
			self.skyboxEntity = skybox
		} catch {
			logger.error("Environment skybox failed: \(error.localizedDescription, privacy: .public)")
		}

		updateIBLRotation(configuration.environmentRotation)
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
			let intensity = RealityKitConfiguration.hydraLinearExposureGain(
				forEV: exposure
			)

			var material =
				(model.materials.first as? UnlitMaterial) ?? UnlitMaterial()
			let color = PlatformColor(
				red: CGFloat(intensity),
				green: CGFloat(intensity),
				blue: CGFloat(intensity),
				alpha: 1.0
			)
			material.color = .init(tint: color, texture: material.color.texture)

			var newModel = model
			newModel.materials = [material]
			skybox.components.set(newModel)
		}
	}

	@MainActor
	private func updateIBLRotation(_ degrees: Float) {
		// Hydra Storm and RealityKit map the equirectangular zero-meridian to
		// opposite world directions. Adding π aligns both engines so the same
		// rotation slider value produces matching panorama orientation.
		let radians = degrees * .pi / 180.0 + .pi

		let orientation: simd_quatf
		if runtime.isZUp {
			// Match Hydra's USD XformCommonAPI: Rx(90°) * Rz(rotation°)
			// In quaternion multiply order: tilt * spin applies spin first, then tilt
			let tilt = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
			let spin = simd_quatf(angle: radians, axis: [0, 0, 1])
			orientation = tilt * spin
		} else {
			orientation = simd_quatf(angle: radians, axis: [0, 1, 0])
		}

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

	/// High-tessellation UV sphere for skybox use. Poles use triangle fans to
	/// avoid degenerate zero-area quads that cause MeshResource.generate to fail.
	/// 128 longitude segments eliminate the faceted banding visible with
	/// `.generateSphere()`'s ~36 segments at large radii.
	private static func makeSkyboxSphere(
		radius: Float,
		lonSegments: Int = 128,
		latSegments: Int = 64
	) throws -> MeshResource {
		// Vertex layout: 1 north pole + (latSegments-1) rings of (lonSegments+1) + 1 south pole
		let ringVerts = lonSegments + 1 // +1 for UV seam duplication
		let vertexCount = 2 + (latSegments - 1) * ringVerts

		var positions = [SIMD3<Float>]()
		var normals = [SIMD3<Float>]()
		var uvs = [SIMD2<Float>]()
		positions.reserveCapacity(vertexCount)
		normals.reserveCapacity(vertexCount)
		uvs.reserveCapacity(vertexCount)

		// North pole (index 0)
		positions.append(SIMD3<Float>(0, radius, 0))
		normals.append(SIMD3<Float>(0, 1, 0))
		uvs.append(SIMD2<Float>(0.5, 0))

		// Body rings (lat 1 … latSegments-1)
		for lat in 1..<latSegments {
			let v = Float(lat) / Float(latSegments)
			let theta = v * .pi
			let sinT = sin(theta)
			let cosT = cos(theta)
			for lon in 0...lonSegments {
				let u = Float(lon) / Float(lonSegments)
				let phi = u * 2.0 * .pi
				let x = sinT * cos(phi)
				let y = cosT
				let z = sinT * sin(phi)
				positions.append(SIMD3<Float>(x, y, z) * radius)
				normals.append(SIMD3<Float>(x, y, z))
				uvs.append(SIMD2<Float>(u, v))
			}
		}

		// South pole (last index)
		let southIndex = UInt32(positions.count)
		positions.append(SIMD3<Float>(0, -radius, 0))
		normals.append(SIMD3<Float>(0, -1, 0))
		uvs.append(SIMD2<Float>(0.5, 1))

		var indices = [UInt32]()

		// North pole fan: pole (0) → first ring (indices 1…lonSegments)
		for lon in 0..<UInt32(lonSegments) {
			indices.append(contentsOf: [0, 1 + lon, 1 + lon + 1])
		}

		// Body quads: ring pairs
		for lat in 0..<(latSegments - 2) {
			let ringStart = UInt32(1 + lat * ringVerts)
			let nextRingStart = ringStart + UInt32(ringVerts)
			for lon in 0..<UInt32(lonSegments) {
				let tl = ringStart + lon
				let tr = tl + 1
				let bl = nextRingStart + lon
				let br = bl + 1
				indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
			}
		}

		// South pole fan: last ring → pole
		let lastRingStart = UInt32(1 + (latSegments - 2) * ringVerts)
		for lon in 0..<UInt32(lonSegments) {
			indices.append(contentsOf: [lastRingStart + lon, southIndex, lastRingStart + lon + 1])
		}

		var descriptor = MeshDescriptor(name: "SkyboxSphere")
		descriptor.positions = MeshBuffer(positions)
		descriptor.normals = MeshBuffer(normals)
		descriptor.textureCoordinates = MeshBuffer(uvs)
		descriptor.primitives = .triangles(indices)
		return try MeshResource.generate(from: [descriptor])
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
