import ComposableArchitecture
import CoreImage
import ImageIO
import OSLog
import RealityKit
import StageViewOverlay
import SwiftUI
import simd
import UniformTypeIdentifiers

#if os(macOS)
	import AppKit
	private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
	import QuartzCore
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
	@State private var gridLoadRequestID = UUID()
	/// Stable box holding the post-process outline effect (macOS 26+).
	@State private var outlineBox = OutlineEffectBox()
	/// Incremented to force a RealityView update cycle when outline state changes.
	@State private var outlineGeneration = 0
	
	// Grid throttling: track last update time and bounds to avoid excessive refreshes
	@State private var lastGridUpdateTime: Date = Date.distantPast
	@State private var lastGridBoundsExtent: Double = 0
	private static let gridUpdateInterval: TimeInterval = 0.5 // Max 2 updates per second
	private static let gridBoundsThreshold: Double = 0.05 // 5% change threshold

	// Environment slider throttling: track pending values and debounce updates
	@State private var pendingExposure: Float?
	@State private var pendingRotation: Float?
	private static let environmentSliderDebounceMs: UInt64 = 50 // 50ms debounce
	private static let environmentBlurDebounceMs: UInt64 = 120 // heavier than exposure/rotation
	#if os(iOS)
	@State private var imageCaptureBridge = ViewportImageCaptureBridge()
	#endif

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

	private var resolvedAppearance: ResolvedStageViewAppearance {
		store.appearance.resolvedAppearance(for: colorScheme)
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
			.task { await observeLoadRequests() }
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
				runtime.setExternalSceneBounds(store.sceneBounds)
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
			.onChange(of: store.sceneBounds) { _, newBounds in
				Task { @MainActor in
					runtime.setExternalSceneBounds(newBounds)
				}
			}
			.onChange(of: runtime.modelEntity.map { ObjectIdentifier($0) }) {
				_,
				newId in
				if let entity = runtime.modelEntity, newId != nil {
					loadModel(entity)
				} else {
					// Clear the loaded model when modelEntity becomes nil
					let anchor = rootEntity?.findEntity(named: "ModelAnchor")
					anchor?.children.first(where: { $0.name == "LoadedModel" })?.removeFromParent()
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
		guard rootEntity != nil else { return nil }
		guard let requestID = store.environmentRequestID?.uuidString else { return nil }
		return "\(requestID)-\(effectiveEnvironmentBlurBucket)"
	}

	private var effectiveEnvironmentBlurBucket: Int {
		guard store.environmentURL?.lastPathComponent.lowercased().hasPrefix("ibl.") == true else {
			return 0
		}
		let bucketCount = 12.0
		let normalized = Double(min(max(configuration.environmentBlurAmount, 0), 1))
		return Int((normalized * bucketCount).rounded(.toNearestOrAwayFromZero))
	}

	/// Combined task ID: fires only after a load request exists and the viewport
	/// has both mounted its scene root and become active.
	/// NOTE: Retained for environment task pattern; load observation now uses
	/// withObservationTracking in observeLoadRequests().

	@ViewBuilder
	private var observedViewportEnvironment: some View {
		observedViewportLifecycle
			.task(id: environmentTaskID) {
				guard environmentTaskID != nil else { return }
				try? await Task.sleep(for: .milliseconds(Self.environmentBlurDebounceMs))
				await updateEnvironment(store.environmentURL)
			}
		.task(id: configuration.environmentExposure) {
			// Debounce exposure updates to avoid sluggish UI during slider dragging
			try? await Task.sleep(for: .milliseconds(Self.environmentSliderDebounceMs))
			await MainActor.run {
				updateIBLExposure(configuration.environmentExposure)
			}
		}
		.task(id: configuration.environmentRotation) {
			// Debounce rotation updates to avoid sluggish UI during slider dragging
			try? await Task.sleep(for: .milliseconds(Self.environmentSliderDebounceMs))
			await MainActor.run {
				updateIBLRotation(configuration.environmentRotation)
			}
		}
		.onChange(of: configuration.showEnvironmentBackground) { _, _ in
			skyboxEntity?.isEnabled = configuration.showEnvironmentBackground
		}
		.onChange(of: configuration.selectionHighlightStyle) { _, _ in
			updateSelectionHighlight(for: runtime.selectedPrimPath)
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
				updateSkyboxRadius(for: newBounds)
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
			.onChange(of: store.appearance) { _, _ in
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
			.background(resolvedBackgroundColor)
			#if os(iOS)
			.overlay {
				ViewportImageCaptureProbe(bridge: imageCaptureBridge)
					.allowsHitTesting(false)
			}
			.task(id: store.imageCaptureRequestID) {
				await captureViewportImageIfRequested(resolvedBackgroundColor: resolvedBackgroundColor)
			}
			#endif
	}

	private var resolvedBackgroundColor: Color {
		let background = resolvedAppearance.backgroundColor
		return Color(
			red: Double(background.x),
			green: Double(background.y),
			blue: Double(background.z),
			opacity: Double(background.w)
		)
	}

	@ViewBuilder
	private var viewportStack: some View {
		ZStack {
			realityViewLayer
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
					.modifier(
						ArcballCameraControls(
							state: $cameraState,
							sceneBounds: runtime.sceneBounds,
							metersPerUnit: configuration.metersPerUnit,
							maxDistance: Float(environmentRadius * 0.9),
							navigationMapping: store.navigationMapping,
							onPick: nonMacPickHandler
						)
					)
				#endif
		}
	}

    private var overlaySnapshot: StageViewOverlaySnapshot {
        return StageViewOverlaySnapshot(
            builtInVisibility: .init(
                showsOrientationGizmo: configuration.showOrientationGizmo,
                showsScaleIndicator: configuration.showScaleIndicator
            ),
            cameraRotation: cameraState.quaternion,
            horizontalFOVDegrees: 60,
            isZUp: runtime.isZUp,
            referenceDepthMeters: runtime.overlayReferenceDepthMeters
        )
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
			refreshGrid()

			if runtime.isActiveViewport(viewportInstanceID), let entity = runtime.modelEntity {
				loadModel(entity)
			}
		} update: { content in
			syncIBLState()
			updateCamera(state: cameraState)
			processRuntimeViewRequests()
			// Grid parameters and position are kept in sync via refreshGrid(), which is
			// triggered by onChange handlers for all relevant state (showGrid,
			// metersPerUnit, isZUp, sceneBounds, colorScheme, store.appearance).
			// No per-frame work is needed here.
			if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
				if let effect = outlineBox.effect as? PostProcessOutlineEffect {
					if let camera = rootEntity?.findEntity(named: "MainCamera") {
						let noRef: Entity? = nil
						effect.setViewMatrix(camera.transformMatrix(relativeTo: noRef).inverse)
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
		guard shouldAcceptViewportPick(runtime: runtime, store: store) else {
			logger.debug("macOSPick ignored because RealityKit viewport is not in a stable loaded state")
			return
		}
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

		// location is AppKit-space (y=0 at bottom). Convert directly to NDC y-up.
		let ndcX = Float(location.x / size.width) * 2 - 1
		let ndcY = Float(location.y / size.height) * 2 - 1

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
			guard let path else {
				logger.debug("macOSPick hit had no mapped prim path — preserving existing selection")
				return
			}
			runtime.userDidPick(path)
			store.send(.entityPicked(path))
		} else {
			logger.debug("macOSPick no hit — preserving existing selection")
		}
	}
	#endif

	#if !os(macOS)
	private var nonMacPickHandler: (CGPoint, CGSize) -> Void {
		let r = runtime
		let s = store
		return { location, size in
			Task { @MainActor in Self.nonMacPick(at: location, in: size, runtime: r, store: s) }
		}
	}

	@MainActor
	private static func nonMacPick(
		at location: CGPoint,
		in size: CGSize,
		runtime: RealityKitProvider,
		store: StoreOf<StageViewFeature>
	) {
		guard shouldAcceptViewportPick(runtime: runtime, store: store) else { return }
		guard size.width > 0, size.height > 0 else { return }
		guard let scene = runtime.rootEntity?.scene else { return }

		let camera = runtime.rootEntity?.findEntity(named: "MainCamera")
		let fovDegrees = Float(camera?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 60)
		let tanHalfFov = tan(fovDegrees * (.pi / 180) / 2)
		let aspect = Float(size.width / size.height)

		let ndcX = Float(location.x / size.width) * 2 - 1
		let ndcY = 1 - Float(location.y / size.height) * 2

		let localDir = SIMD3<Float>(ndcX * tanHalfFov * aspect, ndcY * tanHalfFov, -1)
		let t = runtime.cameraWorldTransform
		let camPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
		let worldDir = simd_normalize(SIMD3<Float>(
			t.columns.0.x * localDir.x + t.columns.1.x * localDir.y + t.columns.2.x * localDir.z,
			t.columns.0.y * localDir.x + t.columns.1.y * localDir.y + t.columns.2.y * localDir.z,
			t.columns.0.z * localDir.x + t.columns.1.z * localDir.y + t.columns.2.z * localDir.z
		))

		let hits = scene.raycast(
			origin: camPos,
			direction: worldDir,
			length: 100_000,
			query: .all,
			mask: .all,
			relativeTo: nil
		)

		if let _ = hits.first {
			let path = runtime.preferredPickPrimPath(from: hits.map(\.entity))
			guard let path else { return }
			runtime.userDidPick(path)
			store.send(.entityPicked(path))
		}
	}
	#endif

	@MainActor
	private static func shouldAcceptViewportPick(
		runtime: RealityKitProvider,
		store: StoreOf<StageViewFeature>
	) -> Bool {
		guard store.activeLoadCommand == nil else { return false }
		guard store.modelURL != nil else { return false }
		guard runtime.isLoaded else { return false }
		guard runtime.modelEntity != nil else { return false }
		return true
	}

	/// Observes store load request changes using `withObservationTracking` inside
	/// a long-lived `.task`. This runs independently of SwiftUI's body evaluation,
	/// so it fires reliably even when the view is behind `AnyView` or
	/// `NSHostingController` boundaries that break `.onChange` delivery.
	private func observeLoadRequests() async {
		var lastHandledRequestID: UUID?
		var activeLoadTask: Task<Void, Never>?

		func scheduleCurrentRequest() {
			let currentRequestID = store.loadRequestID
			guard currentRequestID != lastHandledRequestID else { return }
			lastHandledRequestID = currentRequestID
			activeLoadTask?.cancel()
			activeLoadTask = Task {
				await handleLoadRequestIfNeeded(requestID: currentRequestID)
			}
		}

		// Process the initial state on mount
		scheduleCurrentRequest()

		// Then observe changes via withObservationTracking
		while !Task.isCancelled {
			let requestID = await withCheckedContinuation { continuation in
				withObservationTracking {
					_ = store.loadRequestID
				} onChange: {
					Task { @MainActor in
						continuation.resume(returning: store.loadRequestID)
					}
				}
			}
			guard !Task.isCancelled else { break }
			logger.debug(
				"observeLoadRequests: detected requestID change to \(requestID.uuidString, privacy: .public) viewport=\(self.viewportInstanceID.uuidString, privacy: .public)"
			)
			scheduleCurrentRequest()
		}

		activeLoadTask?.cancel()
	}

	private func handleLoadRequestIfNeeded(requestID currentRequestID: UUID) async {
		guard let command = store.activeLoadCommand else {
			logger.debug(
				"handleLoadRequestIfNeeded: no active command for requestID=\(currentRequestID.uuidString, privacy: .public) modelURL=\(store.modelURL?.lastPathComponent ?? "nil", privacy: .public)"
			)
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
		guard !Task.isCancelled else { return }

		// Wait for rootEntity if it hasn't been set yet
		if rootEntity == nil {
			logger.debug(
				"handleLoadRequestIfNeeded: waiting for rootEntity mount, command=\(command.id.uuidString, privacy: .public)"
			)
			for _ in 0..<100 {
				try? await Task.sleep(for: .milliseconds(50))
				if rootEntity != nil || Task.isCancelled { break }
			}
			guard rootEntity != nil else {
				guard !Task.isCancelled else { return }
				logger.error(
					"handleLoadRequestIfNeeded: rootEntity never mounted, failing command=\(command.id.uuidString, privacy: .public)"
				)
				await MainActor.run {
					store.send(.loadCommandFailed(command.id, "Viewport scene root was not mounted"))
				}
				return
			}
		}
		guard !Task.isCancelled else { return }

		guard runtime.isActiveViewport(viewportInstanceID) else {
			logger.warning(
				"handleLoadRequestIfNeeded skipped: viewport \(self.viewportInstanceID.uuidString, privacy: .public) is not active"
			)
			return
		}

		logger.info(
			"Viewport \(self.viewportInstanceID.uuidString, privacy: .public) loading model: \(command.url.lastPathComponent, privacy: .public) [\(String(describing: command.mode), privacy: .public)] command=\(command.id.uuidString, privacy: .public)"
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
			logger.info("Model loaded successfully for command \(command.id.uuidString, privacy: .public)")
		} catch is CancellationError {
			guard runtime.isActiveViewport(viewportInstanceID) else { return }
			_ = await MainActor.run {
				store.send(.loadCommandFailed(command.id, "Load cancelled"))
			}
			logger.error(
				"Model load cancelled for command \(command.id.uuidString, privacy: .public)"
			)
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
				guard bounds.isFrameable else {
					logger.error(
						"Skipping auto-frame because scene bounds are invalid. min=\(String(describing: bounds.min), privacy: .public) max=\(String(describing: bounds.max), privacy: .public) maxExtent=\(bounds.maxExtent)"
					)
					applyIBLReceiver(to: entity)
					return
				}
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
		updateSkyboxPosition(using: camera)
	}

	@MainActor
	private func refreshGrid() {
		guard let root = rootEntity else { return }
		let bounds = runtime.sceneBounds

		if !configuration.showGrid {
			gridLoadRequestID = UUID()
			gridEntity?.removeFromParent()
			gridEntity = nil
			return
		}

		// If the grid entity already exists, just update its parameters.
		if let existing = gridEntity {
			let metrics = RealityKitGrid.metrics(
				metersPerUnit: configuration.metersPerUnit,
				worldExtent: Double(bounds.maxExtent),
				appearance: resolvedAppearance.viewportAppearance
			)
			logger.notice(
				"viewport_grid_refresh existing=true bounds_min=(\(bounds.min.x, format: .fixed(precision: 4)),\(bounds.min.y, format: .fixed(precision: 4)),\(bounds.min.z, format: .fixed(precision: 4))) bounds_max=(\(bounds.max.x, format: .fixed(precision: 4)),\(bounds.max.y, format: .fixed(precision: 4)),\(bounds.max.z, format: .fixed(precision: 4))) center=(\(bounds.center.x, format: .fixed(precision: 4)),\(bounds.center.y, format: .fixed(precision: 4)),\(bounds.center.z, format: .fixed(precision: 4))) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4)) radius_m=\(metrics.radiusMeters, format: .fixed(precision: 4)) minor_m=\(metrics.minorStepMeters, format: .fixed(precision: 4)) major_m=\(metrics.majorStepMeters, format: .fixed(precision: 4))"
			)
			RealityKitGrid.updateProceduralGrid(
				entity: existing,
				metersPerUnit: configuration.metersPerUnit,
				worldExtent: Double(bounds.maxExtent),
				isZUp: configuration.isZUp,
				appearance: resolvedAppearance.viewportAppearance,
				minorColorOverride: resolvedAppearance.gridMinorColor,
				majorColorOverride: resolvedAppearance.gridMajorColor
			)
			alignGrid(existing)
			// Re-parent if needed when the viewport root is recreated during refreshes.
			if existing.parent !== root {
				existing.removeFromParent()
				root.addChild(existing)
			}
			return
		}

		// First time — async load.
		let requestID = UUID()
		gridLoadRequestID = requestID
		logger.notice(
			"viewport_grid_refresh existing=false bounds_min=(\(bounds.min.x, format: .fixed(precision: 4)),\(bounds.min.y, format: .fixed(precision: 4)),\(bounds.min.z, format: .fixed(precision: 4))) bounds_max=(\(bounds.max.x, format: .fixed(precision: 4)),\(bounds.max.y, format: .fixed(precision: 4)),\(bounds.max.z, format: .fixed(precision: 4))) center=(\(bounds.center.x, format: .fixed(precision: 4)),\(bounds.center.y, format: .fixed(precision: 4)),\(bounds.center.z, format: .fixed(precision: 4))) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4))"
		)
		Task {
			await loadProceduralGrid(into: root, requestID: requestID)
		}
	}

	@MainActor
	private func updateSkyboxRadius(for bounds: SceneBounds) {
		guard let skybox = skyboxEntity else { return }
		guard var model = skybox.components[ModelComponent.self] else { return }

		let targetRadius = Float(Swift.max(1000.0, Double(bounds.maxExtent) * 10.0))
		let currentBounds = skybox.visualBounds(relativeTo: skybox)
		let currentRadius = Swift.max(
			currentBounds.extents.x,
			Swift.max(currentBounds.extents.y, currentBounds.extents.z)
		) * 0.5

		guard currentRadius.isFinite else { return }
		guard Swift.abs(currentRadius - targetRadius) > Swift.max(1.0, targetRadius * 0.01) else {
			return
		}

		model.mesh = .generateSphere(radius: targetRadius)
		skybox.components.set(model)
	}

	@MainActor
	private func updateSkyboxPosition(using camera: Entity) {
		guard let skybox = skyboxEntity else { return }
		skybox.position = camera.position(relativeTo: rootEntity)
	}

	@MainActor
	private func loadProceduralGrid(into root: Entity, requestID: UUID) async {
		guard configuration.showGrid else { return }

		guard
			let grid = await RealityKitGrid.createProceduralGridEntity(
				metersPerUnit: configuration.metersPerUnit,
				worldExtent: Double(runtime.sceneBounds.maxExtent),
				isZUp: configuration.isZUp,
				appearance: resolvedAppearance.viewportAppearance,
				minorColorOverride: resolvedAppearance.gridMinorColor,
				majorColorOverride: resolvedAppearance.gridMajorColor
			)
		else { return }

		guard configuration.showGrid else { return }
		guard gridLoadRequestID == requestID else { return }
		guard rootEntity === root else { return }

		// Remove any stale grid attached to the current root before adopting the new one.
		root.findEntity(named: "ReferenceGrid")?.removeFromParent()
		gridEntity?.removeFromParent()
		alignGrid(grid)
		self.gridEntity = grid
		root.addChild(grid)
	}

	@MainActor
	private func alignGrid(_ grid: Entity) {
		let bounds = runtime.sceneBounds
		let verticalInset = Float(
			Swift.max(
				0.0005,
				Swift.min(
					Double(configuration.metersPerUnit) * 0.001,
					Swift.max(Double(bounds.maxExtent) * 0.001, 0.01)
				)
			)
		)
		grid.position = SIMD3<Float>(
			bounds.center.x,
			bounds.min.y - verticalInset,
			bounds.center.z
		)
		logger.notice(
			"viewport_grid_align position=(\(grid.position.x, format: .fixed(precision: 4)),\(grid.position.y, format: .fixed(precision: 4)),\(grid.position.z, format: .fixed(precision: 4))) vertical_inset=\(verticalInset, format: .fixed(precision: 6)) bounds_min_y=\(bounds.min.y, format: .fixed(precision: 4)) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4))"
		)
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
		let bounds = runtime.sceneBounds
		let focus = bounds.isFrameable ? bounds.center : .zero
		let distance =
			bounds.isFrameable
			? ViewportTuning.defaultCameraDistance(
				sceneBounds: bounds,
				metersPerUnit: configuration.metersPerUnit
			)
			: 5.0
		cameraState = ArcballCameraState(
			focus: focus,
			rotation: SIMD3<Float>(-20 * .pi / 180, 0, 0),
			distance: distance
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

		guard let url = url else {
			// No environment — hide skybox, clear its texture.
			ibl.components.remove(ImageBasedLightComponent.self)
			updateIBLLightIntensity()
			skyboxEntity?.isEnabled = false
			logger.debug("Environment cleared: customIBL=false showBackground=false")
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

		// Image processing: If the user requested "Soft Reflections" by pointing to 'ibl.hdr',
		// we intercept it to avoid feeding a low-energy irradiance map to RealityKit.
		// Instead, we find the sharp 'ref.hdr', apply a hardware blur to it, and pass THAT
		// to RealityKit. This preserves HDR peaks (allowing max exposure to work properly) while
		// still providing soft specular and a soft background.
		let isBlurRequested = ["ibl.hdr", "ibl.exr"].contains(url.lastPathComponent.lowercased())
		let blurURL = url.deletingLastPathComponent().appendingPathComponent(
			url.lastPathComponent.lowercased().replacingOccurrences(of: "ibl", with: "blur")
		)
		let refURL = url.deletingLastPathComponent().appendingPathComponent(
			url.lastPathComponent.lowercased().replacingOccurrences(of: "ibl", with: "ref")
		)
		let resolvedFileURL: URL = {
			if !isBlurRequested {
				return url
			}
			if FileManager.default.fileExists(atPath: blurURL.path) {
				return blurURL
			}
			if FileManager.default.fileExists(atPath: refURL.path) {
				return refURL
			}
			return url
		}()

		let blurAmount = min(max(configuration.environmentBlurAmount, 0), 1)

		let resolvedCGImage: CGImage = await Task.detached(priority: .userInitiated) {
			let fileName = url.lastPathComponent.lowercased()
			
			if !isBlurRequested {
				return cgImage
			}
			
			let opts: [String: Any] = [
				kCGImageSourceShouldAllowFloat as String: true,
				kCGImageSourceShouldCache as String: false,
			]
			
			// Priority 1: User-provided pre-blurred HDR image
			if FileManager.default.fileExists(atPath: blurURL.path) {
				if let src = CGImageSourceCreateWithURL(blurURL as CFURL, opts as CFDictionary),
				   let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
					return img
				}
			}
			
			// Priority 2: Load the sharp ref map and blur it at runtime to preserve peak brightness
			if FileManager.default.fileExists(atPath: refURL.path) {
				if let src = CGImageSourceCreateWithURL(refURL as CFURL, opts as CFDictionary),
				   let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
					guard blurAmount > 0.001 else {
						return img
					}
					
					let ciImage = CIImage(cgImage: img)
					if let filter = CIFilter(name: "CIGaussianBlur") {
						filter.setValue(ciImage, forKey: kCIInputImageKey)
						// Scale the default soft-reflection blur with a normalized user control.
						let radius = (CGFloat(img.height) / 35.0) * CGFloat(blurAmount)
						filter.setValue(radius, forKey: kCIInputRadiusKey)
						if let output = filter.outputImage {
							// NSNull() tells CoreImage not to apply color management, preserving raw HDR values
							// Use .RGBAf to preserve 32-bit float precision through the blur.
							// The default createCGImage(_:from:) produces 8-bit output which
							// strips HDR peak values, causing EnvironmentResource to throw or
							// receive a non-HDR image with no light energy above 1.0.
							let context = CIContext(options: [.workingColorSpace: NSNull()])
							if let blurredCGImage = context.createCGImage(
								output,
								from: ciImage.extent,
								format: .RGBAf,
								colorSpace: nil
							) {
								return blurredCGImage
							}
						}
					}
					// If blur fails, return sharp map rather than diffuse map
					return img
				}
			}
			
			return cgImage
		}.value

		let nextEnvironmentResource: EnvironmentResource?
		do {
			let resource = try await EnvironmentResource(equirectangular: resolvedCGImage, withName: resourceName)
			nextEnvironmentResource = resource
		} catch {
			logger.error("Environment IBL failed: \(error.localizedDescription, privacy: .public)")
			nextEnvironmentResource = nil
		}

		// Update skybox texture on the existing sphere entity.
		var nextSkyboxModel: ModelComponent?
		if let skybox = skyboxEntity,
		   let existingModel = skybox.components[ModelComponent.self]
		{
			do {
				// Use the same resolved runtime image as the IBL input so the visible
				// background tracks soft-reflection blur, but keep it as a 2D texture
				// for the unlit sphere to avoid cube-texture binding crashes on iOS.
				let texture = try TextureResource.generate(
					from: resolvedCGImage,
					options: .init(semantic: .color)
				)
				var material = UnlitMaterial()
				material.color = .init(texture: .init(texture))
				nextSkyboxModel = ModelComponent(
					mesh: existingModel.mesh,
					materials: [material]
				)
			} catch {
				logger.error("Skybox texture load failed: \(error.localizedDescription, privacy: .public)")
			}
		} else {
			logger.warning("Skybox entity not found or has no ModelComponent")
		}

		// Only swap lighting/background once replacements are ready. This avoids
		// flicker during blur scrubs when in-flight loads are canceled.
		if let nextEnvironmentResource {
			var nextIBLComponent = ImageBasedLightComponent(source: .single(nextEnvironmentResource))
			nextIBLComponent.intensityExponent = configuration.realityKitIntensityExponent
			nextIBLComponent.inheritsRotation = true
			ibl.components.set(nextIBLComponent)
			if let model = runtime.modelEntity {
				applyIBLReceiver(to: model)
			}
		}

		if let nextSkyboxModel, let skybox = skyboxEntity {
			skybox.components.set(nextSkyboxModel)
			skybox.isEnabled = configuration.showEnvironmentBackground
			logger.debug("Skybox updated: enabled=\(self.configuration.showEnvironmentBackground, privacy: .public)")
		}

		// Apply all current visual state immediately — don't wait for the next
		// syncIBLState() call from the update: closure, which would cause a
		// brief flash at default exposure after every environment reload.
		updateIBLExposure(configuration.environmentExposure)
		updateIBLRotation(configuration.environmentRotation)
		updateIBLLightIntensity()
		logger.debug(
			"Environment updated: customIBL=\(ibl.components[ImageBasedLightComponent.self] != nil, privacy: .public) exposure=\(configuration.environmentExposure, privacy: .public) showBackground=\(self.configuration.showEnvironmentBackground, privacy: .public)"
		)
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
			skybox.isEnabled = configuration.showEnvironmentBackground
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
		let useIBL = iblEntity?.components[ImageBasedLightComponent.self] != nil
		if let key = root.findEntity(named: "KeyLight") as? DirectionalLight {
			key.light.intensity = useIBL ? 0 : 2000
		}
		if let fill = root.findEntity(named: "FillLight") as? DirectionalLight {
			fill.light.intensity = useIBL ? 0 : 1000
		}
		let keyIntensity = (root.findEntity(named: "KeyLight") as? DirectionalLight)?.light.intensity ?? -1
		let fillIntensity = (root.findEntity(named: "FillLight") as? DirectionalLight)?.light.intensity ?? -1
		logger.debug(
			"Lighting mode: customIBL=\(useIBL, privacy: .public) keyLight=\(keyIntensity, privacy: .public) fillLight=\(fillIntensity, privacy: .public)"
		)
	}

	#if os(iOS)
	@MainActor
	private func captureViewportImageIfRequested(resolvedBackgroundColor: Color) async {
		guard store.imageCaptureRequestID != nil else { return }

		imageCaptureBridge.backgroundColor = UIColor(resolvedBackgroundColor)

		do {
			let image = try await imageCaptureBridge.captureImage()
			let fileURL = try persistCapturedViewportImage(image)
			store.send(.delegate(.imageCaptured(fileURL)))
		} catch {
			logger.error("Viewport capture failed: \(error.localizedDescription, privacy: .public)")
			store.send(.delegate(.imageCaptureFailed(error.localizedDescription)))
		}
	}

	private func persistCapturedViewportImage(_ image: UIImage) throws -> URL {
		guard let cgImage = image.cgImage else {
			throw ViewportImageCaptureError.encodingFailed
		}

		let directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("gantry-viewport-captures", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)

		let fileURL = directoryURL
			.appendingPathComponent("viewport-\(UUID().uuidString)")
			.appendingPathExtension(UTType.jpeg.preferredFilenameExtension ?? "jpg")

		guard let destination = CGImageDestinationCreateWithURL(
			fileURL as CFURL,
			UTType.jpeg.identifier as CFString,
			1,
			nil
		) else {
			throw ViewportImageCaptureError.encodingFailed
		}

		CGImageDestinationAddImage(
			destination,
			cgImage,
			viewportImageMetadata() as CFDictionary
		)
		guard CGImageDestinationFinalize(destination) else {
			throw ViewportImageCaptureError.encodingFailed
		}
		return fileURL
	}

	private func viewportImageMetadata() -> [CFString: Any] {
		let shortVersion = Bundle.main.object(
			forInfoDictionaryKey: "CFBundleShortVersionString"
		) as? String
		let buildVersion = Bundle.main.object(
			forInfoDictionaryKey: "CFBundleVersion"
		) as? String
		let versionSuffix =
			if let shortVersion, let buildVersion {
				" \(shortVersion) (\(buildVersion))"
			} else if let shortVersion {
				" \(shortVersion)"
			} else if let buildVersion {
				" (\(buildVersion))"
			} else {
				""
			}

		let software = "Gantry\(versionSuffix)"
		let description = "Exported from Gantry: Scene Converter"
		return [
			kCGImageDestinationLossyCompressionQuality: 0.92,
			kCGImagePropertyTIFFDictionary: [
				kCGImagePropertyTIFFSoftware: software,
				kCGImagePropertyTIFFImageDescription: description,
				kCGImagePropertyTIFFArtist: "Preflight",
			],
			kCGImagePropertyExifDictionary: [
				kCGImagePropertyExifUserComment: description,
			],
		]
	}
	#endif

}

extension SIMD4 where Scalar == Float {
	fileprivate var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite && w.isFinite
	}
}

#if os(iOS)
@MainActor
private final class ViewportImageCaptureBridge {
	weak var probeView: UIView?
	var backgroundColor: UIColor?

	func captureImage() async throws -> UIImage {
		guard let captureView = resolvedCaptureView() else {
			throw ViewportImageCaptureError.captureViewUnavailable
		}
		guard captureView.bounds.isEmpty == false else {
			throw ViewportImageCaptureError.emptyBounds
		}

		await Task.yield()

		let format = UIGraphicsImageRendererFormat(for: captureView.traitCollection)
		format.opaque = true
		format.scale = captureView.window?.screen.scale ?? UIScreen.main.scale
		let renderer = UIGraphicsImageRenderer(bounds: captureView.bounds, format: format)
		return renderer.image { _ in
			(backgroundColor ?? resolvedBackgroundColor(in: captureView)).setFill()
			UIBezierPath(rect: captureView.bounds).fill()
			captureView.drawHierarchy(in: captureView.bounds, afterScreenUpdates: true)
		}
	}

	private func resolvedCaptureView() -> UIView? {
		guard let probeView else { return nil }

		for candidate in probeView.superviewChain() {
			if let target = candidate.deepestRenderableDescendant() {
				return target
			}
		}

		return probeView.superview
	}

	private func resolvedBackgroundColor(in view: UIView) -> UIColor {
		for candidate in view.superviewChain() {
			let color = candidate.backgroundColor
			if let color, color.cgColor.alpha > 0 {
				return color
			}
		}
		return .systemBackground
	}
}

private enum ViewportImageCaptureError: LocalizedError {
	case captureViewUnavailable
	case emptyBounds
	case encodingFailed

	var errorDescription: String? {
		switch self {
		case .captureViewUnavailable:
			return "Could not locate the active viewport for image export."
		case .emptyBounds:
			return "The active viewport has no visible bounds to export."
		case .encodingFailed:
			return "Failed to encode the captured viewport image."
		}
	}
}

private struct ViewportImageCaptureProbe: UIViewRepresentable {
	let bridge: ViewportImageCaptureBridge

	func makeUIView(context: Context) -> ViewportImageCaptureProbeView {
		let view = ViewportImageCaptureProbeView()
		view.bridge = bridge
		return view
	}

	func updateUIView(_ uiView: ViewportImageCaptureProbeView, context: Context) {
		uiView.bridge = bridge
	}
}

private final class ViewportImageCaptureProbeView: UIView {
	weak var bridge: ViewportImageCaptureBridge? {
		didSet {
			bridge?.probeView = self
		}
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		isOpaque = false
		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		backgroundColor = .clear
		isOpaque = false
		isUserInteractionEnabled = false
	}
}

private extension UIView {
	func superviewChain() -> [UIView] {
		var result: [UIView] = []
		var current = superview
		while let view = current {
			result.append(view)
			current = view.superview
		}
		return result
	}

	func deepestRenderableDescendant() -> UIView? {
		if subviews.isEmpty {
			return hasRenderableContent ? self : nil
		}

		for subview in subviews.reversed() {
			if let match = subview.deepestRenderableDescendant() {
				return match
			}
		}

		return hasRenderableContent ? self : nil
	}

	var hasRenderableContent: Bool {
		layer is CAMetalLayer || subviews.contains(where: { $0.hasRenderableContent })
	}
}
#endif

extension SIMD3 where Scalar == Float {
	fileprivate var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite
	}
}
