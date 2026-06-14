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
	private typealias PlatformImage = NSImage
#elseif os(iOS) || os(visionOS)
	import QuartzCore
	import UIKit
	private typealias PlatformColor = UIColor
	private typealias PlatformImage = UIImage
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

#if os(visionOS)
private struct VolumeModelPresentationComponent: Component, Sendable {
	var fitScale: Float?
	var yawRadians: Float
	var scaleMultiplier: Float
	var turntableStartYaw: Float?
	var transientTiltRadians: Float
	var transientTiltStartRadians: Float?
	var scaleStartMultiplier: Float?
	var viewMax: SIMD3<Float>
	var viewMin: SIMD3<Float>

	init(
		fitScale: Float? = nil,
		yawRadians: Float = 0,
		scaleMultiplier: Float = 1,
		turntableStartYaw: Float? = nil,
		transientTiltRadians: Float = 0,
		transientTiltStartRadians: Float? = nil,
		scaleStartMultiplier: Float? = nil,
		viewMax: SIMD3<Float>,
		viewMin: SIMD3<Float>
	) {
		self.fitScale = fitScale
		self.yawRadians = yawRadians
		self.scaleMultiplier = scaleMultiplier
		self.turntableStartYaw = turntableStartYaw
		self.transientTiltRadians = transientTiltRadians
		self.transientTiltStartRadians = transientTiltStartRadians
		self.scaleStartMultiplier = scaleStartMultiplier
		self.viewMax = viewMax
		self.viewMin = viewMin
	}
}

@MainActor
private final class RealityViewContentBoundsConverter {
	private var convertToContentSpace: ((Rect3D) -> BoundingBox)?

	func install(_ content: RealityViewContent) {
		convertToContentSpace = { rect in
			content.convert(rect, from: .local, to: content)
		}
	}

	func convert(_ rect: Rect3D) -> BoundingBox? {
		convertToContentSpace?(rect)
	}
}
#endif

public struct RealityKitStageView: View {
	@Environment(\.colorScheme) private var colorScheme
	#if os(visionOS)
		@Environment(\.physicalMetrics) private var physicalMetrics
	#endif
	let runtime: RealityKitProvider
	var configuration: RealityKitConfiguration

	var store: StoreOf<StageViewFeature>

	@State private var rootEntity: Entity?
	@State private var cameraState = ArcballCameraState()
	@State private var selectionHighlightEntity: Entity?
	@State private var outlinedEntityIDs: Set<Entity.ID> = []
	@State private var viewportInstanceID = UUID()
	@State private var gridEntity: Entity?
	@State private var skyboxRadius: Float = 0
	@State private var gridLoadRequestID = UUID()
	#if os(visionOS)
		@State private var contentBoundsConverter = RealityViewContentBoundsConverter()
		@State private var latestVolumeBounds: Rect3D?
		@State private var volumePresentationScalePercent: Double?
	#endif
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
	@State private var iblSyncCache = IBLSyncCache()
	#if os(visionOS)
		@State private var authoredEnvironmentResource: EnvironmentResource?
	#endif
	private static let environmentSliderDebounceMs: UInt64 = 50 // 50ms debounce
	private static let environmentBlurDebounceMs: UInt64 = 120 // heavier than exposure/rotation
	@State private var imageCaptureBridge = ViewportImageCaptureBridge()

	/// Looked up by name from rootEntity — always available after makeSceneRoot().
	private var iblEntity: Entity? { rootEntity?.findEntity(named: "ImageBasedLight") }
	private var skyboxEntity: Entity? { rootEntity?.findEntity(named: "SkyboxSphere") }

	private final class IBLSyncCache {
		var exposure: Float?
		var rotation: Float?
		var intensityExponent: Float?
	}

	private var environmentRadius: Double {
		let extent = Double(runtime.sceneBounds.maxExtent)
		return Swift.max(1000.0, extent * 10.0)
	}

	/// Runtime `sceneBounds` are converted to RealityKit meters by the provider.
	/// Viewport tuning therefore uses 1 meter per coordinate unit.
	private var viewportBoundsMetersPerUnit: Double { 1.0 }

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
		// A configuration-level appearance knob overrides both the store intent
		// and the SwiftUI environment color scheme. `.dark`/`.light` resolve
		// deterministically regardless of `colorScheme`.
		(configuration.appearance ?? store.appearance).resolvedAppearance(for: colorScheme)
	}

	/// Whether the environment background sphere should be drawn.
	///
	/// When a `configuration.appearance` is supplied, the skybox is suppressed by
	/// default so the themed solid background is visible — this is what makes
	/// "pass the system appearance and the viewport themes itself" a one-liner
	/// without the caller touching `showEnvironmentBackground` or the skybox.
	private var effectiveShowEnvironmentBackground: Bool {
		if configuration.appearance != nil {
			return false
		}
		return configuration.showEnvironmentBackground
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
			.task(id: store.loadRequestID) {
				await handleLoadRequestIfNeeded(requestID: store.loadRequestID)
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
				runtime.updateSceneMetadata(
					metersPerUnit: configuration.metersPerUnit,
					isZUp: configuration.isZUp
				)
				runtime.setExternalSceneBounds(store.sceneBounds)
				runtime.setHiddenPrimPaths(Set(store.hiddenPrimPaths))
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
					#if os(visionOS)
						resetCameraInternal()
					#else
						runtime.resetCamera()
					#endif
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
		guard store.environmentURL != nil else { return 0 }
		let bucketCount = 12.0
		let normalized = Double(min(max(configuration.environmentBlurAmount, 0), 1))
		return Int((normalized * bucketCount).rounded(.toNearestOrAwayFromZero))
	}

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
		.task(id: configuration.imageBasedLightingWeight) {
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
		.task(id: configuration.environmentLightingWeight) {
			try? await Task.sleep(for: .milliseconds(Self.environmentSliderDebounceMs))
			await MainActor.run {
				#if os(visionOS)
				if #available(visionOS 26.0, *), let model = runtime.modelEntity {
					applyEnvironmentLightingConfiguration(to: model)
					logSpatialLightingState()
				}
				#endif
			}
		}
		.onChange(of: effectiveShowEnvironmentBackground) { _, _ in
			skyboxEntity?.isEnabled = effectiveShowEnvironmentBackground
		}
		.onChange(of: configuration.selectionHighlightStyle) { _, _ in
			updateSelectionHighlight(for: runtime.selectedPrimPath)
		}
		.onChange(of: configuration.modelDisplayScale) { _, _ in
			applyConfiguredModelTransform()
		}
		.onChange(of: configuration.modelDisplayOffset) { _, _ in
			applyConfiguredModelTransform()
		}
		.onChange(of: configuration.modelDisplaysOnBase) { _, _ in
			applyConfiguredModelTransform()
		}
		.onChange(of: configuration.volumePresentationMode) { _, _ in
			applyConfiguredModelTransform()
		}
		.onChange(of: configuration.enablesModelManipulation) { _, _ in
			applyConfiguredModelTransform()
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
				runtime.setExternalSceneBounds(store.sceneBounds)
				refreshGrid()
				updateCamera(state: cameraState)
			}
			.onChange(of: configuration.isZUp) { _, newValue in
				runtime.updateSceneMetadata(
					metersPerUnit: configuration.metersPerUnit,
					isZUp: newValue
				)
				runtime.setExternalSceneBounds(store.sceneBounds)
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
				applyConfiguredModelTransform()
			}
			.onChange(of: colorScheme) { _, _ in
				refreshGrid()
			}
			.onChange(of: store.appearance) { _, _ in
				refreshGrid()
			}
			.onChange(of: cameraState) { _, newState in
				updateCamera(state: newState)
			}
	}

	@ViewBuilder
	private var interactiveViewport: some View {
		observedViewport
			.withLiveTransform(store: store, provider: runtime)
			.withRuntimeBlendShapes(store: store, provider: runtime)
			.withVisibilityProjection(store: store, provider: runtime)
			.background(viewportBackgroundColor)
			.overlay {
				ViewportImageCaptureProbe(bridge: imageCaptureBridge)
					.allowsHitTesting(false)
			}
			.task(id: store.imageCaptureRequestID) {
				let captureColor: Color = effectiveShowEnvironmentBackground
					? resolvedBackgroundColor
					: .clear
				await captureViewportImageIfRequested(resolvedBackgroundColor: captureColor)
			}
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

	private var viewportBackgroundColor: Color {
		#if os(visionOS)
			.clear
		#else
			resolvedBackgroundColor
		#endif
	}

	@ViewBuilder
	private var viewportStack: some View {
		let stack = ZStack {
			realityViewLayer
				#if os(macOS)
					.modifier(
						ArcballCameraControls(
							state: $cameraState,
							sceneBounds: runtime.sceneBounds,
							metersPerUnit: viewportBoundsMetersPerUnit,
							maxDistance: Float(environmentRadius * 0.9),
							navigationMapping: store.navigationMapping,
							onPick: macOSPickHandler,
							applyEntityTransform: { [runtime] state in runtime.applyCameraTransform(state) },
							entityDrag: entityDragHooks
						)
					)
				#elseif os(visionOS)
					.allowsHitTesting(true)
				#else
					.modifier(
						ArcballCameraControls(
							state: $cameraState,
							sceneBounds: runtime.sceneBounds,
							metersPerUnit: viewportBoundsMetersPerUnit,
							maxDistance: Float(environmentRadius * 0.9),
							navigationMapping: store.navigationMapping,
							onPick: nonMacPickHandler,
							applyEntityTransform: { [runtime] state in runtime.applyCameraTransform(state) }
						)
					)
				#endif
		}
		.viewportOverlay(
			items: ViewportOverlayCollection()
				.orientationGizmo(anchor: .bottomLeading)
				.scaleIndicator(anchor: .top),
			builtInVisibility: .init(
				showsOrientationGizmo: configuration.showOrientationGizmo,
				showsScaleIndicator: configuration.showScaleIndicator
			),
			snapshot: overlaySnapshot
		)
		#if os(visionOS)
			if #available(visionOS 26.0, *) {
				stack
					.ornament(
						visibility: volumeScaleOrnamentVisibility,
						attachmentAnchor: .scene(.top)
					) {
						if let volumePresentationScalePercent {
							PresentationScaleBadgeView(percent: volumePresentationScalePercent)
						}
					}
			} else {
				stack
			}
		#else
			stack
		#endif
	}

	#if os(visionOS)
	@available(visionOS 26.0, *)
	private var volumeScaleOrnamentVisibility: Visibility {
		guard configuration.showScaleIndicator,
			  volumePresentationScalePercent?.isFinite == true
		else { return .hidden }
		return .visible
	}
	#endif
	private var overlayPresentationScalePercent: Double? {
		#if os(visionOS)
			return volumePresentationScalePercent
		#else
			return nil
		#endif
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
            referenceDepthMeters: runtime.overlayReferenceDepthMeters,
            presentationScalePercent: overlayPresentationScalePercent
        )
    }

	@ViewBuilder
	private var realityViewLayer: some View {
		#if os(visionOS)
			if #available(visionOS 26.0, *) {
				realityView()
					.onGeometryChange3D(for: Rect3D.self) { proxy in
						proxy.frame(in: .local)
					} action: { newBounds in
						latestVolumeBounds = newBounds
						updateVolumePresentationBounds(newBounds)
					}
					.simultaneousGesture(volumeTurntableGesture)
					.simultaneousGesture(volumeScaleGesture)
			} else {
				realityView()
			}
		#else
			realityView()
		#endif
	}

	@ViewBuilder
	private func realityView() -> some View {
		#if os(visionOS)
			RealityView { content in
				logger.notice(
					"realityview_make_invoked viewport=\(self.viewportInstanceID.uuidString, privacy: .public) main=\(Thread.isMainThread, privacy: .public)"
				)
				contentBoundsConverter.install(content)
				let root = makeSceneRoot()
				content.add(root)
				self.rootEntity = root
				runtime.updateRootEntity(root, viewportID: viewportInstanceID)
				if let latestVolumeBounds {
					updateVolumePresentationBounds(latestVolumeBounds)
				}
				if let camera = root.findEntity(named: "MainCamera") {
					runtime.setCameraEntity(camera)
				}
				refreshGrid()

				if runtime.isActiveViewport(viewportInstanceID), let entity = runtime.modelEntity {
					loadModel(entity)
				}
			}
			.overlay {
				if let error = runtime.loadError {
					errorOverlay(error)
				}
			}
		#else
			RealityView { content in
				logger.debug(
					"RealityView content mounted for viewport \(self.viewportInstanceID.uuidString, privacy: .public)"
				)
				let root = makeSceneRoot()
				content.add(root)
				self.rootEntity = root
				runtime.updateRootEntity(root, viewportID: viewportInstanceID)
				if let camera = root.findEntity(named: "MainCamera") {
					runtime.setCameraEntity(camera)
				}
				refreshGrid()

				if runtime.isActiveViewport(viewportInstanceID), let entity = runtime.modelEntity {
					loadModel(entity)
				}
			} update: { content in
				syncIBLState()
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
		#endif
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

	// MARK: - macOS Entity Drag (scene-space, host-routed)

	/// Hooks wiring the macOS camera controls' entity-drag interception to the
	/// provider's scene-space drag API. Active only when interaction mode is
	/// `.entityDrag`.
	private var entityDragHooks: ViewportEntityDragHooks {
		let r = runtime
		let s = store
		let enabled = configuration.interactionMode == .entityDrag
		return ViewportEntityDragHooks(
			isEnabled: enabled,
			hitTest: { location, size in
				Self.entityDragHitTest(at: location, in: size, runtime: r, store: s)
			},
			onBegan: {
				// Only capture the gesture when the provider actually begins a
				// drag (a selected, mapped entity exists). Otherwise return false
				// so the controller falls through to normal camera/pick handling.
				r.beginEntityDrag()
			},
			onChanged: { screenDelta, location, size in
				// `location` is AppKit view space (y-up). The provider's exact
				// scene-point recovery uses a y-down NDC convention, so flip y
				// here to match. The incremental delta is already y-down (the
				// controller flips it at the AppKit boundary).
				let yDownLocation = SIMD2<Double>(
					Double(location.x),
					Double(size.height) - Double(location.y)
				)
				r.updateEntityDrag(
					screenDelta: SIMD2<Double>(Double(screenDelta.width), Double(screenDelta.height)),
					viewLocation: yDownLocation,
					viewSize: SIMD2<Double>(Double(size.width), Double(size.height))
				)
			},
			onEnded: {
				r.endEntityDrag()
			}
		)
	}

	/// Returns `true` if a click at `location` (AppKit y-up: origin bottom-left,
	/// matching `macOSPick`) hits the currently selected entity, so a drag from
	/// there should move the entity rather than the camera.
	@MainActor
	private static func entityDragHitTest(
		at location: CGPoint,
		in size: CGSize,
		runtime: RealityKitProvider,
		store: StoreOf<StageViewFeature>
	) -> Bool {
		guard shouldAcceptViewportPick(runtime: runtime, store: store) else { return false }
		guard let selectedPath = runtime.selectedPrimPath else { return false }
		guard size.width > 0, size.height > 0 else { return false }
		guard let scene = runtime.rootEntity?.scene else { return false }

		let camera = runtime.rootEntity?.findEntity(named: "MainCamera")
		let fovDegrees = Float(camera?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 60)
		let aspect = Float(size.width / size.height)
		// macOS click location is AppKit-space (y up from bottom-left); the
		// picking path builds NDC directly without a y flip.
		let ndcX = Float(location.x / size.width) * 2 - 1
		let ndcY = Float(location.y / size.height) * 2 - 1
		let ray = SceneSpaceDragMath.cameraRay(
			ndc: SIMD2<Float>(ndcX, ndcY),
			cameraWorldTransform: runtime.cameraWorldTransform,
			fovDegrees: fovDegrees,
			aspect: aspect
		)

		let hits = scene.raycast(
			origin: ray.origin, direction: ray.direction, length: 100_000,
			query: .all, mask: .all, relativeTo: nil
		)
		guard let path = runtime.preferredPickPrimPath(from: hits.map(\.entity)) else { return false }
		// Treat the pick as the selected entity when its resolved path matches,
		// or is a descendant/ancestor of, the selection.
		return path == selectedPath
			|| path.hasPrefix(selectedPath + "/")
			|| selectedPath.hasPrefix(path + "/")
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
		let path = runtime.preferredPickPrimPath(from: hits.map(\.entity))
		if let hit = hits.first, let path {
			logger.debug("macOSPick hit entity='\(hit.entity.name, privacy: .public)' path=\(path, privacy: .public)")
			runtime.userDidPick(path)
			store.send(.entityPicked(path))
		} else {
			logger.debug("macOSPick no hit — clearing selection")
			runtime.userDidPick(nil)
			store.send(.entityPicked(nil))
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

		let path = runtime.preferredPickPrimPath(from: hits.map(\.entity))
		if let _ = hits.first, let path {
			runtime.userDidPick(path)
			store.send(.entityPicked(path))
		} else {
			runtime.userDidPick(nil)
			store.send(.entityPicked(nil))
		}
	}
	#endif

	@MainActor
	private static func shouldAcceptViewportPick(
		runtime: RealityKitProvider,
		store: StoreOf<StageViewFeature>
	) -> Bool {
		guard store.activeLoadCommand == nil else { return false }
		// Injected-entity sources are gated on the runtime being loaded alone,
		// so a host feeding the viewport via `setModel` does not have to fake a
		// `modelURL` to unlock picking.
		if !runtime.isExternallyDriven {
			guard store.modelURL != nil else { return false }
		}
		guard runtime.isLoaded else { return false }
		guard runtime.modelEntity != nil else { return false }
		return true
	}

	private func handleLoadRequestIfNeeded(requestID currentRequestID: UUID) async {
		guard let command = store.activeLoadCommand else {
			logger.debug(
				"handleLoadRequestIfNeeded: no active command for requestID=\(currentRequestID.uuidString, privacy: .public) modelURL=\(store.modelURL?.lastPathComponent ?? "nil", privacy: .public)"
			)
			// Injected-entity sources own their model via `setModel` and have no
			// `modelURL`; do not tear them down here.
			if store.modelURL == nil, configuration.source != .injectedEntity {
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
				try await runtime.refresh(command.url, viewportID: viewportInstanceID)
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

		#if !os(visionOS)
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
		#endif

		let camera = PerspectiveCamera()
		camera.name = "MainCamera"
		if var component = camera.components[PerspectiveCameraComponent.self] {
			let clip = ViewportTuning.clippingRange(
				distance: cameraState.distance,
				sceneBounds: runtime.sceneBounds,
				metersPerUnit: viewportBoundsMetersPerUnit,
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
			#if os(visionOS)
				if let latestVolumeBounds {
					updateVolumePresentationBounds(latestVolumeBounds)
				}
			#endif
			applyConfiguredModelTransform()
			runtime.setHiddenPrimPaths(Set(store.hiddenPrimPaths))
			runtime.startEmbeddedAnimationsIfAvailable(autoPlay: false)

			prepareForPicking(entity)
			runtime.restoreExternallySuppliedSceneBounds()
			refreshGrid()
			#if os(visionOS)
				if #available(visionOS 26.0, *) {
					applyEnvironmentLightingConfiguration(to: entity)
				}
			#endif

			if !preserveCamera, rootEntity?.findEntity(named: "MainCamera") != nil {
				let bounds = runtime.sceneBounds
				guard bounds.isFrameable else {
					logger.error(
						"Skipping auto-frame because scene bounds are invalid. min=\(String(describing: bounds.min), privacy: .public) max=\(String(describing: bounds.max), privacy: .public) maxExtent=\(bounds.maxExtent)"
					)
					syncIBLReceiver(on: entity)
					return
				}
				let distance = ViewportTuning.defaultCameraDistance(
					sceneBounds: bounds,
					metersPerUnit: viewportBoundsMetersPerUnit
				)

				var newState = cameraState
				newState.focus = viewportFocus(for: bounds)
				newState.distance = distance
				newState.rotation = SIMD3<Float>(-20 * .pi / 180, 0, 0)
				applyCameraStateImmediately(newState)
			}

			syncIBLReceiver(on: entity)
		}
	}

	@MainActor
	private func applyConfiguredModelTransform() {
		guard let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
			  let entity = anchor.children.first(where: { $0.name == "LoadedModel" })
		else { return }
		#if os(visionOS)
			if shouldFitModelToVolumeFloor,
			   let presentation = anchor.components[VolumeModelPresentationComponent.self] {
				applyConfiguredModelTransform(
					anchor: anchor,
					model: entity,
					presentation: presentation
				)
				return
			}
		#endif
		applyConfiguredModelTransform(anchor: anchor)
	}

	#if os(visionOS)
	@MainActor
	private func updateVolumePresentationBounds(_ bounds: Rect3D) {
		let fallbackBounds = centeredPhysicalBounds(for: bounds)
		let contentBounds = contentBoundsConverter.convert(bounds)
		let resolvedBounds = contentBounds ?? fallbackBounds
		let extents = resolvedBounds.extents
		logger.notice(
			"volume_bounds_updated source=\(contentBounds == nil ? "physical_metrics_fallback" : "reality_content_convert", privacy: .public) raw_min=(\(bounds.min.x, privacy: .public),\(bounds.min.y, privacy: .public),\(bounds.min.z, privacy: .public)) raw_max=(\(bounds.max.x, privacy: .public),\(bounds.max.y, privacy: .public),\(bounds.max.z, privacy: .public)) resolved_min=(\(resolvedBounds.min.x, privacy: .public),\(resolvedBounds.min.y, privacy: .public),\(resolvedBounds.min.z, privacy: .public)) resolved_max=(\(resolvedBounds.max.x, privacy: .public),\(resolvedBounds.max.y, privacy: .public),\(resolvedBounds.max.z, privacy: .public)) fallback_min=(\(fallbackBounds.min.x, privacy: .public),\(fallbackBounds.min.y, privacy: .public),\(fallbackBounds.min.z, privacy: .public)) fallback_max=(\(fallbackBounds.max.x, privacy: .public),\(fallbackBounds.max.y, privacy: .public),\(fallbackBounds.max.z, privacy: .public)) main=\(Thread.isMainThread, privacy: .public)"
		)
		guard extents.x.isFinite, extents.y.isFinite, extents.z.isFinite,
			  extents.x > 0, extents.y > 0, extents.z > 0
		else { return }
		guard let anchor = rootEntity?.findEntity(named: "ModelAnchor") else { return }
		let existing = anchor.components[VolumeModelPresentationComponent.self]
		anchor.components.set(
			VolumeModelPresentationComponent(
				fitScale: existing?.fitScale,
				yawRadians: existing?.yawRadians ?? 0,
				scaleMultiplier: existing?.scaleMultiplier ?? 1,
				turntableStartYaw: existing?.turntableStartYaw,
				transientTiltRadians: existing?.transientTiltRadians ?? 0,
				transientTiltStartRadians: existing?.transientTiltStartRadians,
				scaleStartMultiplier: existing?.scaleStartMultiplier,
				viewMax: resolvedBounds.max,
				viewMin: resolvedBounds.min
			)
		)
		applyConfiguredModelTransform()
		refreshGrid()
	}

	@MainActor
	private func centeredPhysicalBounds(for bounds: Rect3D) -> BoundingBox {
		let boundsInMeters = physicalMetrics.convert(bounds, to: .meters)
		let extents = SIMD3<Float>(
			Float(boundsInMeters.max.x - boundsInMeters.min.x),
			Float(boundsInMeters.max.y - boundsInMeters.min.y),
			Float(boundsInMeters.max.z - boundsInMeters.min.z)
		)
		let halfExtents = extents * 0.5
		return BoundingBox(min: -halfExtents, max: halfExtents)
	}
	#endif

	@MainActor
	private func applyConfiguredModelTransform(anchor: Entity) {
		let displayScale = configuration.modelDisplayScale.isFinite
			&& configuration.modelDisplayScale > 0
			? configuration.modelDisplayScale
			: 1.0
		anchor.scale = SIMD3<Float>(repeating: displayScale)
		anchor.position = configuration.modelDisplayOffset
		#if os(visionOS)
			updateModelManipulation(for: anchor)
		#endif
	}

	#if os(visionOS)
	private var shouldFitModelToVolumeFloor: Bool {
		configuration.modelDisplaysOnBase
			|| configuration.volumePresentationMode == .fitToVolumeFloor
	}

	@MainActor
	private func applyConfiguredModelTransform(
		anchor: Entity,
		model: Entity,
		presentation: VolumeModelPresentationComponent
	) {
		let displayScale = configuration.modelDisplayScale.isFinite
			&& configuration.modelDisplayScale > 0
			? configuration.modelDisplayScale
			: 1.0
		let modelBounds = model.visualBounds(relativeTo: anchor)
		let modelExtents = modelBounds.extents
		let viewExtents = presentation.viewMax - presentation.viewMin
		guard modelExtents.x.isFinite, modelExtents.y.isFinite, modelExtents.z.isFinite,
			  modelExtents.x > 0, modelExtents.y > 0, modelExtents.z > 0,
			  viewExtents.x.isFinite, viewExtents.y.isFinite, viewExtents.z.isFinite,
			  viewExtents.x > 0, viewExtents.y > 0, viewExtents.z > 0
		else { return }

		let fitScale = min(
			viewExtents.x / modelExtents.x,
			min(viewExtents.y / modelExtents.y, viewExtents.z / modelExtents.z)
		) * 0.92
		guard fitScale.isFinite, fitScale > 0 else { return }

		var updatedPresentation = presentation
		updatedPresentation.fitScale = fitScale
		updatedPresentation.scaleMultiplier = Self.clampedVolumeScaleMultiplier(
			presentation.scaleMultiplier,
			fitScale: fitScale
		)
		anchor.components.set(updatedPresentation)
		applyVolumePresentationTransform(
			anchor: anchor,
			modelBounds: modelBounds,
			presentation: updatedPresentation,
			displayScale: displayScale
		)
		updateModelManipulation(for: anchor)
		logger.notice(
			"volume_presentation_fit fit_scale=\(fitScale, privacy: .public) final_scale=\(anchor.scale.x, privacy: .public) multiplier=\(updatedPresentation.scaleMultiplier, privacy: .public) yaw=\(updatedPresentation.yawRadians, privacy: .public) model_min=(\(modelBounds.min.x, privacy: .public),\(modelBounds.min.y, privacy: .public),\(modelBounds.min.z, privacy: .public)) model_max=(\(modelBounds.max.x, privacy: .public),\(modelBounds.max.y, privacy: .public),\(modelBounds.max.z, privacy: .public)) model_extents=(\(modelExtents.x, privacy: .public),\(modelExtents.y, privacy: .public),\(modelExtents.z, privacy: .public)) view_extents=(\(viewExtents.x, privacy: .public),\(viewExtents.y, privacy: .public),\(viewExtents.z, privacy: .public)) anchor_position=(\(anchor.position.x, privacy: .public),\(anchor.position.y, privacy: .public),\(anchor.position.z, privacy: .public))"
		)
	}

	@MainActor
	private func applyVolumePresentationTransform(
		anchor: Entity,
		modelBounds: BoundingBox,
		presentation: VolumeModelPresentationComponent,
		displayScale: Float,
		animationDuration: TimeInterval = 0
	) {
		guard let fitScale = presentation.fitScale,
			  fitScale.isFinite,
			  fitScale > 0
		else { return }
		let scale = fitScale
			* displayScale
			* Self.clampedVolumeScaleMultiplier(
				presentation.scaleMultiplier,
				fitScale: fitScale
			)
		let viewCenter = (presentation.viewMin + presentation.viewMax) * 0.5
		let rotation = volumePresentationOrientation(for: presentation)
		let transformedBounds = rotatedScaledBounds(
			for: modelBounds,
			rotation: rotation,
			scale: scale
		)
		let transformedCenter = (transformedBounds.min + transformedBounds.max) * 0.5
		let transform = Transform(
			scale: SIMD3<Float>(repeating: scale),
			rotation: rotation,
			translation: configuration.modelDisplayOffset + SIMD3<Float>(
				viewCenter.x - transformedCenter.x,
				presentation.viewMin.y - transformedBounds.min.y,
				viewCenter.z - transformedCenter.z
			)
		)
		if animationDuration > 0 {
			anchor.move(
				to: transform,
				relativeTo: anchor.parent,
				duration: animationDuration,
				timingFunction: .easeOut
			)
		} else {
			anchor.transform = transform
		}
		volumePresentationScalePercent = Double(
			scale / Swift.max(displayScale, Float.leastNonzeroMagnitude) * 100
		)
		logger.debug(
			"volume_presentation_apply fit_scale=\(fitScale, privacy: .public) display_scale=\(displayScale, privacy: .public) multiplier=\(presentation.scaleMultiplier, privacy: .public) final_scale=\(scale, privacy: .public) yaw=\(presentation.yawRadians, privacy: .public) transient_tilt=\(presentation.transientTiltRadians, privacy: .public) animation=\(animationDuration, privacy: .public) view_center=(\(viewCenter.x, privacy: .public),\(viewCenter.y, privacy: .public),\(viewCenter.z, privacy: .public)) transformed_min=(\(transformedBounds.min.x, privacy: .public),\(transformedBounds.min.y, privacy: .public),\(transformedBounds.min.z, privacy: .public)) transformed_max=(\(transformedBounds.max.x, privacy: .public),\(transformedBounds.max.y, privacy: .public),\(transformedBounds.max.z, privacy: .public)) transformed_center=(\(transformedCenter.x, privacy: .public),\(transformedCenter.y, privacy: .public),\(transformedCenter.z, privacy: .public)) position=(\(transform.translation.x, privacy: .public),\(transform.translation.y, privacy: .public),\(transform.translation.z, privacy: .public))"
		)
	}

	private func rotatedScaledBounds(
		for bounds: BoundingBox,
		rotation: simd_quatf,
		scale: Float
	) -> BoundingBox {
		let corners = [
			SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.min.z),
			SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.max.z),
			SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.min.z),
			SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.max.z),
			SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.min.z),
			SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.max.z),
			SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.min.z),
			SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.max.z),
		]
		var minPoint = SIMD3<Float>(
			Float.greatestFiniteMagnitude,
			Float.greatestFiniteMagnitude,
			Float.greatestFiniteMagnitude
		)
		var maxPoint = SIMD3<Float>(
			-Float.greatestFiniteMagnitude,
			-Float.greatestFiniteMagnitude,
			-Float.greatestFiniteMagnitude
		)
		for corner in corners {
			let transformed = rotation.act(corner * scale)
			minPoint = simd_min(minPoint, transformed)
			maxPoint = simd_max(maxPoint, transformed)
		}
		return BoundingBox(min: minPoint, max: maxPoint)
	}

	private func volumePresentationOrientation(
		for presentation: VolumeModelPresentationComponent
	) -> simd_quatf {
		// The spatial volume floor is Y-up regardless of the authored USD stage axis.
		let yaw = simd_quatf(angle: presentation.yawRadians, axis: SIMD3<Float>(0, 1, 0))
		let tilt = simd_quatf(angle: presentation.transientTiltRadians, axis: SIMD3<Float>(1, 0, 0))
		return yaw * tilt
	}

	private static func clampedVolumeScaleMultiplier(
		_ value: Float,
		fitScale: Float?
	) -> Float {
		guard value.isFinite else { return 1 }
		let realSizeMultiplier: Float
		if let fitScale, fitScale.isFinite, fitScale > 1 {
			realSizeMultiplier = 1 / fitScale
		} else {
			realSizeMultiplier = 0.35
		}
		let lowerBound = max(0.01, min(0.35, realSizeMultiplier))
		return min(1.0, max(lowerBound, value))
	}

	private static func clampedTransientTilt(_ value: Float) -> Float {
		guard value.isFinite else { return 0 }
		return min(0.7, max(-0.7, value))
	}

	private static func clampedYawInertia(_ value: Float) -> Float {
		guard value.isFinite else { return 0 }
		return min(0.75, max(-0.75, value))
	}

	@available(visionOS 26.0, *)
	private var volumeTurntableGesture: some Gesture {
		DragGesture(minimumDistance: 8)
			.onChanged { value in
				applyVolumeTurntableDragChanged(value)
			}
			.onEnded { value in
				applyVolumeTurntableDragEnded(value)
				if let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
				   var presentation = anchor.components[VolumeModelPresentationComponent.self] {
					presentation.turntableStartYaw = nil
					presentation.transientTiltStartRadians = nil
					anchor.components.set(presentation)
					logger.notice(
						"volume_turntable_ended yaw=\(presentation.yawRadians, privacy: .public) transient_tilt=\(presentation.transientTiltRadians, privacy: .public)"
					)
				}
			}
	}

	@available(visionOS 26.0, *)
	private var volumeScaleGesture: some Gesture {
		MagnifyGesture(minimumScaleDelta: 0.01)
			.onChanged { value in
				applyVolumeScaleChanged(value)
			}
			.onEnded { value in
				applyVolumeScaleChanged(value)
				if let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
				   var presentation = anchor.components[VolumeModelPresentationComponent.self] {
					presentation.scaleStartMultiplier = nil
					anchor.components.set(presentation)
					logger.notice(
						"volume_scale_ended multiplier=\(presentation.scaleMultiplier, privacy: .public)"
					)
				}
			}
	}

	@available(visionOS 26.0, *)
	@MainActor
	private func applyVolumeTurntableDragChanged(_ value: DragGesture.Value) {
		guard configuration.enablesModelManipulation,
			  shouldFitModelToVolumeFloor,
			  let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
			  let model = anchor.children.first(where: { $0.name == "LoadedModel" }),
			  var presentation = anchor.components[VolumeModelPresentationComponent.self],
			  presentation.fitScale != nil
		else { return }

		let startYaw = presentation.turntableStartYaw ?? presentation.yawRadians
		if presentation.turntableStartYaw == nil {
			presentation.turntableStartYaw = startYaw
		}
		let startTilt = presentation.transientTiltStartRadians ?? presentation.transientTiltRadians
		if presentation.transientTiltStartRadians == nil {
			presentation.transientTiltStartRadians = startTilt
		}
		let radiansPerPoint = Float.pi / 360
		presentation.yawRadians = startYaw + Float(value.translation.width) * radiansPerPoint
		presentation.transientTiltRadians = Self.clampedTransientTilt(
			startTilt + Float(value.translation.height) * radiansPerPoint
		)
		anchor.components.set(presentation)
		let displayScale = configuration.modelDisplayScale.isFinite
			&& configuration.modelDisplayScale > 0
			? configuration.modelDisplayScale
			: 1.0
		applyVolumePresentationTransform(
			anchor: anchor,
			modelBounds: model.visualBounds(relativeTo: anchor),
			presentation: presentation,
			displayScale: displayScale
		)
	}

	@available(visionOS 26.0, *)
	@MainActor
	private func applyVolumeTurntableDragEnded(_ value: DragGesture.Value) {
		guard configuration.enablesModelManipulation,
			  shouldFitModelToVolumeFloor,
			  let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
			  let model = anchor.children.first(where: { $0.name == "LoadedModel" }),
			  var presentation = anchor.components[VolumeModelPresentationComponent.self],
			  presentation.fitScale != nil
		else { return }

		let startYaw = presentation.turntableStartYaw ?? presentation.yawRadians
		let radiansPerPoint = Float.pi / 360
		let predictedExtraWidth = Float(
			value.predictedEndTranslation.width - value.translation.width
		)
		let inertiaYaw = Self.clampedYawInertia(predictedExtraWidth * radiansPerPoint)
		presentation.yawRadians = startYaw + Float(value.translation.width) * radiansPerPoint + inertiaYaw
		presentation.transientTiltRadians = 0
		presentation.turntableStartYaw = nil
		presentation.transientTiltStartRadians = nil
		anchor.components.set(presentation)
		let displayScale = configuration.modelDisplayScale.isFinite
			&& configuration.modelDisplayScale > 0
			? configuration.modelDisplayScale
			: 1.0
		applyVolumePresentationTransform(
			anchor: anchor,
			modelBounds: model.visualBounds(relativeTo: anchor),
			presentation: presentation,
			displayScale: displayScale,
			animationDuration: 0.28
		)
	}

	@available(visionOS 26.0, *)
	@MainActor
	private func applyVolumeScaleChanged(_ value: MagnifyGesture.Value) {
		guard configuration.enablesModelManipulation,
			  shouldFitModelToVolumeFloor,
			  let anchor = rootEntity?.findEntity(named: "ModelAnchor"),
			  let model = anchor.children.first(where: { $0.name == "LoadedModel" }),
			  var presentation = anchor.components[VolumeModelPresentationComponent.self],
			  presentation.fitScale != nil
		else { return }

		let startScale = presentation.scaleStartMultiplier ?? presentation.scaleMultiplier
		if presentation.scaleStartMultiplier == nil {
			presentation.scaleStartMultiplier = startScale
		}
		presentation.scaleMultiplier = Self.clampedVolumeScaleMultiplier(
			startScale * Float(value.magnification),
			fitScale: presentation.fitScale
		)
		anchor.components.set(presentation)
		let displayScale = configuration.modelDisplayScale.isFinite
			&& configuration.modelDisplayScale > 0
			? configuration.modelDisplayScale
			: 1.0
		applyVolumePresentationTransform(
			anchor: anchor,
			modelBounds: model.visualBounds(relativeTo: anchor),
			presentation: presentation,
			displayScale: displayScale
		)
	}

	@MainActor
	private func updateModelManipulation(for anchor: Entity) {
		guard #available(visionOS 26.0, *) else { return }
		if configuration.enablesModelManipulation {
			anchor.components.remove(ManipulationComponent.self)
			anchor.components.remove(ManipulationComponent.HitTarget.self)
			logger.debug(
				"volume_manipulation_enabled system_manipulation=disabled gestures=swiftui_direct"
			)
		} else {
			anchor.components.remove(ManipulationComponent.self)
			anchor.components.remove(ManipulationComponent.HitTarget.self)
		}
	}
	#endif

	@MainActor
	private func applyCameraStateImmediately(_ newState: ArcballCameraState) {
		cameraState = newState
		runtime.applyCameraTransform(newState)
		updateCamera(state: newState)
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
				metersPerUnit: viewportBoundsMetersPerUnit,
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
		updateSkyboxPosition(using: camera)
	}

	@MainActor
	private func refreshGrid() {
		guard let root = rootEntity else { return }
		let bounds = runtime.sceneBounds
		let gridWorldExtent = gridReferenceExtent(for: bounds)
		let gridRadiusOverrideMeters = gridRadiusOverrideMeters(for: bounds)

		if !configuration.showGrid {
			gridLoadRequestID = UUID()
			gridEntity?.removeFromParent()
			gridEntity = nil
			return
		}

		// If the grid entity already exists, just update its parameters.
		if let existing = gridEntity {
			let metrics = RealityKitGrid.metrics(
				metersPerUnit: viewportBoundsMetersPerUnit,
				worldExtent: Double(gridWorldExtent),
				radiusMetersOverride: gridRadiusOverrideMeters,
				appearance: resolvedAppearance.viewportAppearance
			)
			logger.notice(
				"viewport_grid_refresh existing=true bounds_min=(\(bounds.min.x, format: .fixed(precision: 4)),\(bounds.min.y, format: .fixed(precision: 4)),\(bounds.min.z, format: .fixed(precision: 4))) bounds_max=(\(bounds.max.x, format: .fixed(precision: 4)),\(bounds.max.y, format: .fixed(precision: 4)),\(bounds.max.z, format: .fixed(precision: 4))) center=(\(bounds.center.x, format: .fixed(precision: 4)),\(bounds.center.y, format: .fixed(precision: 4)),\(bounds.center.z, format: .fixed(precision: 4))) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4)) grid_extent=\(gridWorldExtent, format: .fixed(precision: 4)) radius_override_m=\(gridRadiusOverrideMeters ?? -1, format: .fixed(precision: 4)) radius_m=\(metrics.radiusMeters, format: .fixed(precision: 4)) minor_m=\(metrics.minorStepMeters, format: .fixed(precision: 4)) major_m=\(metrics.majorStepMeters, format: .fixed(precision: 4))"
			)
			RealityKitGrid.updateProceduralGrid(
				entity: existing,
				metersPerUnit: viewportBoundsMetersPerUnit,
				worldExtent: Double(gridWorldExtent),
				isZUp: configuration.isZUp,
				appearance: resolvedAppearance.viewportAppearance,
				radiusMetersOverride: gridRadiusOverrideMeters,
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
			"viewport_grid_refresh existing=false bounds_min=(\(bounds.min.x, format: .fixed(precision: 4)),\(bounds.min.y, format: .fixed(precision: 4)),\(bounds.min.z, format: .fixed(precision: 4))) bounds_max=(\(bounds.max.x, format: .fixed(precision: 4)),\(bounds.max.y, format: .fixed(precision: 4)),\(bounds.max.z, format: .fixed(precision: 4))) center=(\(bounds.center.x, format: .fixed(precision: 4)),\(bounds.center.y, format: .fixed(precision: 4)),\(bounds.center.z, format: .fixed(precision: 4))) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4)) grid_extent=\(gridWorldExtent, format: .fixed(precision: 4)) radius_override_m=\(gridRadiusOverrideMeters ?? -1, format: .fixed(precision: 4))"
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
		guard Swift.abs(skyboxRadius - targetRadius) > Swift.max(1.0, targetRadius * 0.01) else {
			return
		}

		model.mesh = .generateSphere(radius: targetRadius)
		skybox.components.set(model)
		skyboxRadius = targetRadius
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
				metersPerUnit: viewportBoundsMetersPerUnit,
				worldExtent: Double(gridReferenceExtent(for: runtime.sceneBounds)),
				isZUp: configuration.isZUp,
				appearance: resolvedAppearance.viewportAppearance,
				radiusMetersOverride: gridRadiusOverrideMeters(for: runtime.sceneBounds),
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
		self.gridEntity = grid
		root.addChild(grid)
		alignGrid(grid)
	}

	@MainActor
	private func alignGrid(_ grid: Entity) {
		let bounds = runtime.sceneBounds
		let placement = gridPlacement(for: bounds)
		let verticalInset = Float(
			Swift.max(
				0.0005,
				Swift.min(
					viewportBoundsMetersPerUnit * 0.001,
					Swift.max(Double(bounds.maxExtent) * 0.001, 0.01)
				)
			)
		)
		grid.position = SIMD3<Float>(
			placement.center.x,
			placement.floorY - verticalInset,
			placement.center.z
		)
		let visualBounds = grid.visualBounds(relativeTo: rootEntity)
		let visualCenter = (visualBounds.min + visualBounds.max) * 0.5
		let correction = SIMD3<Float>(
			placement.center.x - visualCenter.x,
			placement.floorY - verticalInset - visualBounds.min.y,
			placement.center.z - visualCenter.z
		)
		if correction.x.isFinite, correction.y.isFinite, correction.z.isFinite {
			grid.position += correction
		}
		let worldPosition = grid.position(relativeTo: nil)
		RealityKitGrid.updateProceduralGridOrigin(
			entity: grid,
			origin: SIMD2<Float>(worldPosition.x, worldPosition.z)
		)
		logger.notice(
			"viewport_grid_align position=(\(grid.position.x, format: .fixed(precision: 4)),\(grid.position.y, format: .fixed(precision: 4)),\(grid.position.z, format: .fixed(precision: 4))) world_origin=(\(worldPosition.x, format: .fixed(precision: 4)),\(worldPosition.z, format: .fixed(precision: 4))) visual_min=(\(visualBounds.min.x, format: .fixed(precision: 4)),\(visualBounds.min.y, format: .fixed(precision: 4)),\(visualBounds.min.z, format: .fixed(precision: 4))) visual_max=(\(visualBounds.max.x, format: .fixed(precision: 4)),\(visualBounds.max.y, format: .fixed(precision: 4)),\(visualBounds.max.z, format: .fixed(precision: 4))) correction=(\(correction.x, format: .fixed(precision: 4)),\(correction.y, format: .fixed(precision: 4)),\(correction.z, format: .fixed(precision: 4))) vertical_inset=\(verticalInset, format: .fixed(precision: 6)) floor_y=\(placement.floorY, format: .fixed(precision: 4)) bounds_min_y=\(bounds.min.y, format: .fixed(precision: 4)) max_extent=\(bounds.maxExtent, format: .fixed(precision: 4))"
		)
	}

	@MainActor
	private func gridReferenceExtent(for bounds: SceneBounds) -> Float {
		#if os(visionOS)
			if shouldFitModelToVolumeFloor,
			   let presentation = rootEntity?
				.findEntity(named: "ModelAnchor")?
				.components[VolumeModelPresentationComponent.self] {
				let viewExtents = presentation.viewMax - presentation.viewMin
				let extent = Swift.max(viewExtents.x, viewExtents.z)
				if extent.isFinite, extent > 0 {
					return extent
				}
			}
		#endif
		return bounds.maxExtent
	}

	@MainActor
	private func gridRadiusOverrideMeters(for bounds: SceneBounds) -> Double? {
		#if os(visionOS)
			if shouldFitModelToVolumeFloor,
			   let presentation = rootEntity?
				.findEntity(named: "ModelAnchor")?
				.components[VolumeModelPresentationComponent.self] {
				let viewExtents = presentation.viewMax - presentation.viewMin
				let floorDiagonal = Double(hypot(viewExtents.x, viewExtents.z))
				let radiusMeters = floorDiagonal * Double(viewportBoundsMetersPerUnit) * 0.5
				if radiusMeters.isFinite, radiusMeters > 0 {
					return radiusMeters
				}
			}
		#endif
		_ = bounds
		return nil
	}

	@MainActor
	private func gridPlacement(for bounds: SceneBounds) -> (center: SIMD3<Float>, floorY: Float) {
		#if os(visionOS)
			if shouldFitModelToVolumeFloor,
			   let presentation = rootEntity?
				.findEntity(named: "ModelAnchor")?
				.components[VolumeModelPresentationComponent.self] {
				let center = (presentation.viewMin + presentation.viewMax) * 0.5
				return (center, presentation.viewMin.y)
			}
		#endif
		return (bounds.center, bounds.min.y)
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
		let focus = bounds.isFrameable ? viewportFocus(for: bounds) : .zero
		let distance =
			bounds.isFrameable
			? ViewportTuning.defaultCameraDistance(
				sceneBounds: bounds,
				metersPerUnit: viewportBoundsMetersPerUnit
			)
			: 5.0
		applyCameraStateImmediately(
			ArcballCameraState(
				focus: focus,
				rotation: SIMD3<Float>(-20 * .pi / 180, 0, 0),
				distance: distance
			)
		)
	}

	private func viewportFocus(for bounds: SceneBounds) -> SIMD3<Float> {
		bounds.center
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

		#if !os(visionOS)
			if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
				clearPostProcessOutline()
			}
		#endif

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
		#if !os(visionOS)
		case .postProcessOutline:
			if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
				applyPostProcessOutline(to: target)
			} else {
				applyOutline(to: target)
			}
		#endif
		}
	}

	#if !os(visionOS)
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
	#endif

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
		logger.warning(
			"Skipping bounding-box selection highlight for \(target.name, privacy: .public) because RealityKit visual bounds are not used."
		)
	}

	@MainActor
	private func syncIBLState() {
		let exposure = configuration.environmentExposure
		if iblSyncCache.exposure != exposure {
			updateIBLExposure(exposure)
			iblSyncCache.exposure = exposure
		}

		let rotation = configuration.environmentRotation
		if iblSyncCache.rotation != rotation {
			updateIBLRotation(rotation)
			iblSyncCache.rotation = rotation
		}

		let intensityExponent = configuration.realityKitIntensityExponent
		if iblSyncCache.intensityExponent != intensityExponent {
			updateIBLLightIntensity()
			iblSyncCache.intensityExponent = intensityExponent
		}
	}

	@MainActor
	private func updateEnvironment(_ url: URL?) async {
		guard let ibl = iblEntity else { return }

		guard let url = url else {
			// No environment — hide skybox, clear its texture.
			ibl.components.remove(ImageBasedLightComponent.self)
			#if os(visionOS)
				authoredEnvironmentResource = nil
				ibl.components.remove(VirtualEnvironmentProbeComponent.self)
			#endif
			if let model = runtime.modelEntity {
				removeIBLReceiver(from: model)
			}
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

		// Blur is driven entirely by environmentBlurAmount — no filename-based detection.
		// The caller always provides the render-quality ref.* URL; cgImage is its content.
		let blurAmount = min(max(configuration.environmentBlurAmount, 0), 1)
		let isBlurRequested = blurAmount > 0.001

		// Optional user-provided pre-blurred sibling (blur.hdr / blur.exr next to ref.hdr).
		let blurFileName = url.lastPathComponent.lowercased()
			.replacingOccurrences(of: "ref", with: "blur")
		let blurURL = url.deletingLastPathComponent().appendingPathComponent(blurFileName)

		let resolvedCGImage: CGImage = await Task.detached(priority: .userInitiated) {
			if !isBlurRequested {
				return cgImage
			}

			let opts: [String: Any] = [
				kCGImageSourceShouldAllowFloat as String: true,
				kCGImageSourceShouldCache as String: false,
			]

			// Priority 1: User-provided pre-blurred HDR sibling.
			if FileManager.default.fileExists(atPath: blurURL.path) {
				if let dp = CGDataProvider(url: blurURL as CFURL),
				   let src = CGImageSourceCreateWithDataProvider(dp, opts as CFDictionary),
				   let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
					return img
				}
			}

			// Priority 2: Gaussian blur the ref.* image at runtime.
			// cgImage is already the render-quality ref.* content — no secondary load needed.
			let ciImage = CIImage(cgImage: cgImage)
			if let filter = CIFilter(name: "CIGaussianBlur") {
				filter.setValue(ciImage, forKey: kCIInputImageKey)
				let radius = (CGFloat(cgImage.height) / 35.0) * CGFloat(blurAmount)
				filter.setValue(radius, forKey: kCIInputRadiusKey)
				if let output = filter.outputImage {
					// workingColorSpace: NSNull() — skip color management, keep raw HDR values.
					// format: .RGBAf — 32-bit float, preserves HDR peaks above 1.0.
					// colorSpace: cgImage.colorSpace — retain the original linear-HDR tag so
					// EnvironmentResource interprets the data correctly. Without this the
					// output is untagged and callers may assume sRGB gamma, blowing out
					// linear float values.
					let context = CIContext(options: [.workingColorSpace: NSNull()])
					if let blurredCGImage = context.createCGImage(
						output,
						from: ciImage.extent,
						format: .RGBAf,
						colorSpace: cgImage.colorSpace
					) {
						return blurredCGImage
					}
				}
			}
			// Blur failed — return the sharp map rather than nothing.
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
			#if os(visionOS)
				authoredEnvironmentResource = nextEnvironmentResource
				if configuration.spatialEnvironmentLightingMode == .virtualEnvironmentProbe {
					ibl.components.remove(ImageBasedLightComponent.self)
					updateVirtualEnvironmentProbe(on: ibl, resource: nextEnvironmentResource)
				} else {
					ibl.components.remove(VirtualEnvironmentProbeComponent.self)
					var nextIBLComponent = ImageBasedLightComponent(source: .single(nextEnvironmentResource))
					nextIBLComponent.intensityExponent = configuration.realityKitIntensityExponent
					nextIBLComponent.inheritsRotation = true
					ibl.components.set(nextIBLComponent)
				}
			#else
				var nextIBLComponent = ImageBasedLightComponent(source: .single(nextEnvironmentResource))
				nextIBLComponent.intensityExponent = configuration.realityKitIntensityExponent
				nextIBLComponent.inheritsRotation = true
				ibl.components.set(nextIBLComponent)
			#endif
			if let model = runtime.modelEntity {
				syncIBLReceiver(on: model)
				#if os(visionOS)
					if #available(visionOS 26.0, *) {
						applyEnvironmentLightingConfiguration(to: model)
					}
				#endif
			}
		}

		if let nextSkyboxModel, let skybox = skyboxEntity {
			skybox.components.set(nextSkyboxModel)
			skybox.isEnabled = effectiveShowEnvironmentBackground
			logger.debug("Skybox updated: enabled=\(self.effectiveShowEnvironmentBackground, privacy: .public)")
		}

		// Apply all current visual state with the environment replacement so
		// there is no flash at default exposure after an environment reload.
		updateIBLExposure(configuration.environmentExposure)
		iblSyncCache.exposure = configuration.environmentExposure
		updateIBLRotation(configuration.environmentRotation)
		iblSyncCache.rotation = configuration.environmentRotation
		updateIBLLightIntensity()
		iblSyncCache.intensityExponent = configuration.realityKitIntensityExponent
		#if !os(visionOS)
			logger.debug(
				"Environment updated: customIBL=\(ibl.components[ImageBasedLightComponent.self] != nil, privacy: .public) exposure=\(configuration.environmentExposure, privacy: .public) showBackground=\(self.configuration.showEnvironmentBackground, privacy: .public)"
			)
		#endif
	}


	@MainActor
	private func updateIBLExposure(_ exposure: Float) {
		#if os(visionOS)
			if configuration.spatialEnvironmentLightingMode == .virtualEnvironmentProbe,
			   let ibl = iblEntity,
			   let resource = authoredEnvironmentResource
			{
				updateVirtualEnvironmentProbe(on: ibl, resource: resource)
			} else if let ibl = iblEntity,
				var iblComp = ibl.components[ImageBasedLightComponent.self]
			{
				iblComp.intensityExponent = configuration.realityKitIntensityExponent
				iblComp.inheritsRotation = true
				ibl.components.set(iblComp)
			}
		#else
			if let ibl = iblEntity,
				var iblComp = ibl.components[ImageBasedLightComponent.self]
			{
				iblComp.intensityExponent = configuration.realityKitIntensityExponent
				iblComp.inheritsRotation = true
				ibl.components.set(iblComp)
			}
		#endif

		if let model = runtime.modelEntity {
			syncIBLReceiver(on: model)
		}
		updateIBLLightIntensity()
		#if os(visionOS)
			logSpatialLightingState()
		#endif

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
			skybox.isEnabled = effectiveShowEnvironmentBackground
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

	private func syncIBLReceiver(on entity: Entity) {
		#if os(visionOS)
			if configuration.spatialEnvironmentLightingMode == .virtualEnvironmentProbe {
				removeIBLReceiver(from: entity)
				return
			}
		#endif
		if iblEntity?.components[ImageBasedLightComponent.self] != nil,
		   configuration.imageBasedLightingWeight > 0
		{
			applyIBLReceiver(to: entity)
		} else {
			removeIBLReceiver(from: entity)
		}
	}

	private func removeIBLReceiver(from entity: Entity) {
		entity.components.remove(ImageBasedLightReceiverComponent.self)
		for child in entity.children {
			removeIBLReceiver(from: child)
		}
	}

	#if os(visionOS)
	@MainActor
	private func updateVirtualEnvironmentProbe(on entity: Entity, resource: EnvironmentResource) {
		guard configuration.imageBasedLightingWeight > 0 else {
			entity.components.set(VirtualEnvironmentProbeComponent(source: .none))
			return
		}

		let probe = VirtualEnvironmentProbeComponent.Probe(
			environment: resource,
			intensityExponent: configuration.realityKitIntensityExponent
		)
		entity.components.set(
			VirtualEnvironmentProbeComponent(source: .single(probe))
		)
	}

	@available(visionOS 26.0, *)
	private func applyEnvironmentLightingConfiguration(to entity: Entity) {
		entity.components.set(
			EnvironmentLightingConfigurationComponent(
				environmentLightingWeight: min(max(configuration.environmentLightingWeight, 0), 1)
			)
		)
	}

	@MainActor
	private func logSpatialLightingState() {
		let mode =
			configuration.spatialEnvironmentLightingMode == .virtualEnvironmentProbe
			? "virtualEnvironmentProbe" : "imageBasedLightReceiver"
		let probeActive =
			iblEntity?.components[VirtualEnvironmentProbeComponent.self] != nil
			&& configuration.imageBasedLightingWeight > 0
		let receiverActive =
			runtime.modelEntity?.components[ImageBasedLightReceiverComponent.self] != nil
		logger.notice(
			"Spatial lighting: mode=\(mode, privacy: .public) iblWeight=\(configuration.imageBasedLightingWeight, privacy: .public) environmentWeight=\(configuration.environmentLightingWeight, privacy: .public) exposureEV=\(configuration.environmentExposure, privacy: .public) authoredExponent=\(configuration.realityKitIntensityExponent, privacy: .public) probeActive=\(probeActive, privacy: .public) receiverActive=\(receiverActive, privacy: .public)"
		)
	}
	#endif

	@MainActor
	private func updateIBLLightIntensity() {
		guard let root = rootEntity else { return }
		#if os(visionOS)
		let useIBL =
			configuration.spatialEnvironmentLightingMode == .virtualEnvironmentProbe
				? iblEntity?.components[VirtualEnvironmentProbeComponent.self] != nil
					&& configuration.imageBasedLightingWeight > 0
				: iblEntity?.components[ImageBasedLightComponent.self] != nil
					&& configuration.imageBasedLightingWeight > 0
		// RealityKit supplies environment lighting on visionOS when no explicit
		// IBL receiver is installed; do not stack desktop preview lights on it.
		let fallbackKeyIntensity: Float = 0
		let fallbackFillIntensity: Float = 0
		#else
		let useIBL =
			iblEntity?.components[ImageBasedLightComponent.self] != nil
			&& configuration.imageBasedLightingWeight > 0
		let fallbackKeyIntensity: Float = 2000
		let fallbackFillIntensity: Float = 1000
		#endif
		if let key = root.findEntity(named: "KeyLight") as? DirectionalLight {
			key.light.intensity = useIBL ? 0 : fallbackKeyIntensity
		}
		if let fill = root.findEntity(named: "FillLight") as? DirectionalLight {
			fill.light.intensity = useIBL ? 0 : fallbackFillIntensity
		}
		#if !os(visionOS)
			let keyIntensity = (root.findEntity(named: "KeyLight") as? DirectionalLight)?.light.intensity ?? -1
			let fillIntensity = (root.findEntity(named: "FillLight") as? DirectionalLight)?.light.intensity ?? -1
			logger.debug(
				"Lighting mode: customIBL=\(useIBL, privacy: .public) keyLight=\(keyIntensity, privacy: .public) fillLight=\(fillIntensity, privacy: .public)"
			)
		#endif
	}

	@MainActor
	private func captureViewportImageIfRequested(resolvedBackgroundColor: Color) async {
		guard store.imageCaptureRequestID != nil else { return }

		do {
			let cgImage = try await captureComposedViewportImage(
				resolvedBackgroundColor: resolvedBackgroundColor
			)
			let fileURL = try persistCapturedViewportImage(cgImage)
			store.send(.delegate(.imageCaptured(fileURL)))
		} catch {
			logger.error("Viewport capture failed: \(error.localizedDescription, privacy: .public)")
			store.send(.delegate(.imageCaptureFailed(error.localizedDescription)))
		}
	}

	private func persistCapturedViewportImage(_ cgImage: CGImage) throws -> URL {
		let imageType = preferredViewportImageType(for: cgImage)
		let directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("gantry-viewport-captures", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)

		let fileURL = directoryURL
			.appendingPathComponent("viewport-\(UUID().uuidString)")
			.appendingPathExtension(imageType.preferredFilenameExtension ?? "img")

		guard let destination = CGImageDestinationCreateWithURL(
			fileURL as CFURL,
			imageType.identifier as CFString,
			1,
			nil
		) else {
			throw ViewportImageCaptureError.encodingFailed
		}

		CGImageDestinationAddImage(
			destination,
			cgImage,
			viewportImageMetadata(for: imageType) as CFDictionary
		)
		guard CGImageDestinationFinalize(destination) else {
			throw ViewportImageCaptureError.encodingFailed
		}
		return fileURL
	}

	private func preferredViewportImageType(for cgImage: CGImage) -> UTType {
		imageHasMeaningfulAlpha(cgImage) ? .png : .jpeg
	}

	private func imageHasMeaningfulAlpha(_ cgImage: CGImage) -> Bool {
		let alphaInfo = cgImage.alphaInfo
		let alphaCapable: Bool
		switch alphaInfo {
		case .none, .noneSkipFirst, .noneSkipLast:
			alphaCapable = false
		default:
			alphaCapable = true
		}
		guard alphaCapable else { return false }

		let width = cgImage.width
		let height = cgImage.height
		guard width > 0, height > 0 else { return false }

		let bytesPerPixel = 4
		let bytesPerRow = width * bytesPerPixel
		let byteCount = bytesPerRow * height
		var rgba = [UInt8](repeating: 0, count: byteCount)

		guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
			let context = CGContext(
				data: &rgba,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: bytesPerRow,
				space: colorSpace,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else {
			return false
		}

		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
		for pixelStart in stride(from: 0, to: byteCount, by: bytesPerPixel) {
			if rgba[pixelStart + 3] < 255 {
				return true
			}
		}
		return false
	}

	private func viewportImageMetadata(for imageType: UTType) -> [CFString: Any] {
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
		var metadata: [CFString: Any] = [
			kCGImagePropertyTIFFDictionary: [
				kCGImagePropertyTIFFSoftware: software,
				kCGImagePropertyTIFFImageDescription: description,
				kCGImagePropertyTIFFArtist: "Preflight",
			],
			kCGImagePropertyExifDictionary: [
				kCGImagePropertyExifUserComment: description,
			],
		]
		if imageType == .jpeg {
			metadata[kCGImageDestinationLossyCompressionQuality] = 0.92
		}
		return metadata
	}

	@MainActor
	private func captureComposedViewportImage(
		resolvedBackgroundColor: Color
	) async throws -> CGImage {
		imageCaptureBridge.backgroundColor = PlatformColor(resolvedBackgroundColor)

		#if os(macOS)
			// Raw-buffer capture via the PostProcess hook — reads targetColorTexture at
			// the latest programmable stage. Known limitation: compositor-level EDR / P3
			// scaling isn't reproduced here, so the file may read slightly darker than
			// the on-screen viewport.
			if #available(macOS 26.0, *) {
				let effect = activePostProcessEffect()
				if outlineBox.effect == nil {
					outlineBox.effect = effect
					outlineGeneration += 1
					// Give RealityView one update cycle to attach the effect before
					// the next postProcess fires.
					try? await Task.sleep(nanoseconds: 32_000_000)
				}
				let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
					?? CGColorSpaceCreateDeviceRGB()
				return try await withCheckedThrowingContinuation {
					(continuation: CheckedContinuation<CGImage, any Error>) in
					effect.requestFrameCapture(colorSpace: colorSpace) { result in
						continuation.resume(with: result)
					}
				}
			} else {
				throw ViewportImageCaptureError.captureUnavailable
			}
		#else
			let image = try await imageCaptureBridge.captureImage()
			guard let cgImage = image.cgImage else {
				throw ViewportImageCaptureError.encodingFailed
			}
			return cgImage
		#endif
	}

	#if os(macOS)
	@available(macOS 26.0, *)
	@MainActor
	private func activePostProcessEffect() -> PostProcessOutlineEffect {
		if let existing = outlineBox.effect as? PostProcessOutlineEffect {
			return existing
		}
		return PostProcessOutlineEffect(
			color: configuration.outlineConfiguration.color,
			radius: 2
		)
	}
	#endif

}

extension SIMD4 where Scalar == Float {
	fileprivate var isFinite: Bool {
		x.isFinite && y.isFinite && z.isFinite && w.isFinite
	}
}

private enum ViewportImageCaptureError: LocalizedError {
	case captureUnavailable
	case captureViewUnavailable
	case emptyBounds
	case encodingFailed

	var errorDescription: String? {
		switch self {
		case .captureUnavailable:
			return "Image export requires the post-processed renderer on this platform version."
		case .captureViewUnavailable:
			return "Could not locate the active viewport for image export."
		case .emptyBounds:
			return "The active viewport has no visible bounds to export."
		case .encodingFailed:
			return "Failed to encode the captured viewport image."
		}
	}
}

@MainActor
private final class ViewportImageCaptureBridge {
	#if os(iOS) || os(visionOS)
		weak var probeView: UIView?
		var backgroundColor: UIColor?
	#elseif os(macOS)
		weak var probeView: NSView?
		var backgroundColor: NSColor?
	#endif

	func captureImage() async throws -> PlatformImage {
		guard let captureView = resolvedCaptureView() else {
			throw ViewportImageCaptureError.captureViewUnavailable
		}
		guard captureView.bounds.isEmpty == false else {
			throw ViewportImageCaptureError.emptyBounds
		}

		await Task.yield()

		#if os(iOS) || os(visionOS)
			let fillColor = backgroundColor ?? resolvedBackgroundColor(in: captureView)
			let opaque = fillColor.cgColor.alpha >= 1.0

			let format = UIGraphicsImageRendererFormat(for: captureView.traitCollection)
			format.opaque = opaque
			format.scale = rendererScale(for: captureView)
			format.preferredRange = .extended
			let renderer = UIGraphicsImageRenderer(bounds: captureView.bounds, format: format)
			return renderer.image { _ in
				if opaque {
					fillColor.setFill()
					UIBezierPath(rect: captureView.bounds).fill()
				}
				captureView.drawHierarchy(in: captureView.bounds, afterScreenUpdates: true)
			}
		#else
			// macOS capture runs through the PostProcess raw-buffer path in
			// captureComposedViewportImage; the bridge is iOS-only for rendering.
			throw ViewportImageCaptureError.captureUnavailable
		#endif
	}

	#if os(iOS) || os(visionOS)
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
				if let color = candidate.backgroundColor, color.cgColor.alpha > 0 {
					return color
				}
			}
			return .systemBackground
		}

		private func rendererScale(for view: UIView) -> CGFloat {
			#if os(iOS)
				return view.window?.screen.scale ?? UIScreen.main.scale
			#else
				return 1
			#endif
		}
	#elseif os(macOS)
		private func resolvedCaptureView() -> NSView? {
			guard let probeView else { return nil }
			for candidate in probeView.superviewChain() {
				if let target = candidate.deepestRenderableDescendant() {
					return target
				}
			}
			return probeView.superview
		}

		private func resolvedBackgroundColor(in view: NSView) -> NSColor {
			for candidate in view.superviewChain() {
				// NSView doesn't have a backgroundColor property by default,
				// but the layer might have one.
				if let color = candidate.layer?.backgroundColor.flatMap({ NSColor(cgColor: $0) }),
				   color.alphaComponent > 0 {
					return color
				}
			}
			return NSColor.windowBackgroundColor
		}
	#endif
}

#if os(iOS) || os(visionOS)
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
		didSet { bridge?.probeView = self }
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
#elseif os(macOS)
private struct ViewportImageCaptureProbe: NSViewRepresentable {
	let bridge: ViewportImageCaptureBridge

	func makeNSView(context: Context) -> ViewportImageCaptureProbeView {
		let view = ViewportImageCaptureProbeView()
		view.bridge = bridge
		return view
	}

	func updateNSView(_ nsView: ViewportImageCaptureProbeView, context: Context) {
		nsView.bridge = bridge
	}
}

private final class ViewportImageCaptureProbeView: NSView {
	weak var bridge: ViewportImageCaptureBridge? {
		didSet { bridge?.probeView = self }
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.backgroundColor = CGColor.clear
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		wantsLayer = true
		layer?.backgroundColor = CGColor.clear
	}
}

private extension NSView {
	func superviewChain() -> [NSView] {
		var result: [NSView] = []
		var current = superview
		while let view = current {
			result.append(view)
			current = view.superview
		}
		return result
	}

	func deepestRenderableDescendant() -> NSView? {
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
