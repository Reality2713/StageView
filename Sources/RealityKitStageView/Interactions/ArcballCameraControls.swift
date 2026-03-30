import OSLog
import SwiftUI
import simd
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

#if os(macOS)
private let pickLogger = Logger(subsystem: "RealityKitStageView", category: "Picking")
#else
private let touchGestureLogger = Logger(subsystem: "RealityKitStageView", category: "TouchInput")
#endif

public struct ArcballCameraState: Equatable, Sendable {
    public var focus: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var distance: Float

    public init(focus: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero, distance: Float = 5.0) {
        self.focus = focus
        self.rotation = rotation
        self.distance = distance
    }

    public var transform: simd_float4x4 {
        let rotX = simd_quatf(angle: rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: rotation.y, axis: [0, 1, 0])
        let rotationMatrix = simd_float4x4(rotY * rotX)

        let translateFocus = simd_float4x4(
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [focus.x, focus.y, focus.z, 1]
        )

        let translateDist = simd_float4x4(
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, distance, 1]
        )

        return translateFocus * rotationMatrix * translateDist
    }

    public var quaternion: simd_quatf {
        let rotX = simd_quatf(angle: rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: rotation.y, axis: [0, 1, 0])
        return rotY * rotX
    }
}

#if os(macOS)

// MARK: - Event Controller (reference type for stable closure captures)

/// Owns NSEvent monitors and all mutable state they read.
/// Closures capture this class instance by reference, so property
/// updates (mapping, camera state, view region) are always visible
/// at event time — no struct-copy staleness.
@MainActor
final class ArcballEventController {
    var navigationMapping: RealityKitNavigationMapping = .apple
    var cameraState: ArcballCameraState = .init()
    var sceneBounds: SceneBounds = .init()
    var metersPerUnit: Double = 1.0
    var maxDistanceOverride: Float?

    var eventRegionView: NSView?

    // Written back to the ViewModifier's @Binding each frame
    var onCameraStateChanged: ((ArcballCameraState) -> Void)?
    /// Called with (location in view coords y-down, view size) when a click is detected.
    var onPick: ((CGPoint, CGSize) -> Void)?

    private(set) var scrollMonitor: LocalScrollEventMonitor?
    private(set) var mouseMonitor: LocalMouseEventMonitor?

    private var activeMouseInteraction: MouseInteraction?
    private var lastMousePoint: CGPoint?
    private var lastClampedEdge: ClampEdge?
    private var mouseDownLocation: CGPoint = .zero
    private var mouseDownTime: Date = Date()

    private enum ClampEdge { case min, max }
    enum MouseInteraction { case orbit, pan, zoom }

    // MARK: - Lifecycle

    func installMonitors() {
        scrollMonitor = LocalScrollEventMonitor { [weak self] event in
            self?.handleScrollEvent(event)
        }
        mouseMonitor = LocalMouseEventMonitor { [weak self] event in
            self?.handleMouseEvent(event)
        }
    }

    func tearDown() {
        scrollMonitor = nil
        mouseMonitor = nil
    }

    // MARK: - Scroll

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard isEventInsideViewport(event) else { return event }

        let scrollInvert: Float = navigationMapping.invertScrollDirection ? -1 : 1
        let zoomInvert: Float = navigationMapping.invertZoomDirection ? -1 : 1
        let action = event.modifierFlags.contains(.option)
            ? navigationMapping.optionScrollAction
            : navigationMapping.scrollAction

        switch action {
        case .zoom:
            let delta = Float(event.scrollingDeltaY) * zoomInvert
            let newDistance = cameraState.distance * exp(delta * 0.01)
            cameraState.distance = clampDistance(newDistance)
        case .pan:
            let multiplier: Float = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
            let deltaX = Float(event.scrollingDeltaX) * multiplier * scrollInvert
            let deltaY = Float(event.scrollingDeltaY) * multiplier * scrollInvert
            applyPan(deltaX: deltaX, deltaY: deltaY)
        case .orbit:
            let deltaX = Float(event.scrollingDeltaX) * scrollInvert
            let deltaY = Float(event.scrollingDeltaY) * scrollInvert
            applyOrbit(deltaX: deltaX, deltaY: deltaY)
        }
        publishState()
        return nil
    }

    // MARK: - Mouse

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        // Click detection: runs for ALL navigation presets; always passes the event through.
        if let view = eventRegionView {
            let localPoint = view.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown where isEventInsideViewport(event):
                mouseDownLocation = localPoint
                mouseDownTime = Date()
                pickLogger.debug("mouseDown inside viewport at \(localPoint.x, privacy: .public),\(localPoint.y, privacy: .public)")
            case .leftMouseDown:
                pickLogger.debug("mouseDown OUTSIDE viewport")
            case .leftMouseUp:
                let distance = hypot(localPoint.x - mouseDownLocation.x, localPoint.y - mouseDownLocation.y)
                let duration = Date().timeIntervalSince(mouseDownTime)
                pickLogger.debug("mouseUp: dist=\(distance, privacy: .public) dur=\(duration, privacy: .public) activeInteraction=\(self.activeMouseInteraction != nil, privacy: .public) insideViewport=\(self.isEventInsideViewport(event), privacy: .public)")
                if activeMouseInteraction == nil && distance < 5 && duration < 0.5 && isEventInsideViewport(event) {
                    let size = view.bounds.size
                    pickLogger.debug("firing onPick at \(localPoint.x, privacy: .public),\(localPoint.y, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
                    onPick?(localPoint, size)
                }
            default:
                break
            }
        } else {
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                pickLogger.debug("eventRegionView is nil — monitor fired but no view")
            }
        }

        // Camera interaction handling (DCC presets only).
        guard !navigationMapping.useSwiftUIGestures else { return event }
        guard shouldHandleMouseEvent(event) else { return event }
        guard let view = eventRegionView else { return event }

        let localPoint = view.convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let interaction = interaction(for: event) else { return event }
            activeMouseInteraction = interaction
            lastMousePoint = localPoint
            return nil

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let interaction = activeMouseInteraction else { return event }
            let previous = lastMousePoint ?? localPoint
            let deltaX = Float(localPoint.x - previous.x)
            let deltaY = Float(localPoint.y - previous.y)

            switch interaction {
            case .orbit:
                applyOrbit(deltaX: deltaX, deltaY: deltaY)
            case .pan:
                applyPan(deltaX: deltaX, deltaY: -deltaY)
            case .zoom:
                let zoomInvert: Float = navigationMapping.invertZoomDirection ? -1 : 1
                let newDistance = cameraState.distance * exp(deltaY * 0.01 * zoomInvert)
                cameraState.distance = clampDistance(newDistance)
            }

            lastMousePoint = localPoint
            publishState()
            return nil

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let handled = activeMouseInteraction != nil
            activeMouseInteraction = nil
            lastMousePoint = nil
            return handled ? nil : event

        default:
            return event
        }
    }

    private func shouldHandleMouseEvent(_ event: NSEvent) -> Bool {
        if activeMouseInteraction != nil {
            guard let view = eventRegionView else { return false }
            return event.window === view.window
        }
        return isEventInsideViewport(event)
    }

    func interaction(for event: NSEvent) -> MouseInteraction? {
        let button = event.buttonNumber
        let mods = event.modifierFlags

        if button == navigationMapping.orbit.button
            && mods.contains(navigationMapping.orbit.modifiers) {
            return .orbit
        }
        if button == navigationMapping.zoom.button
            && mods.contains(navigationMapping.zoom.modifiers) {
            return .zoom
        }
        if button == navigationMapping.pan.button
            && mods.contains(navigationMapping.pan.modifiers) {
            return .pan
        }
        return nil
    }

    // MARK: - Viewport hit test

    func isEventInsideViewport(_ event: NSEvent) -> Bool {
        guard let view = eventRegionView else { return false }
        guard let window = view.window, window == event.window else { return false }
        let viewRectInWindow = view.convert(view.bounds, to: nil)
        let viewRectOnScreen = window.convertToScreen(viewRectInWindow)
        return viewRectOnScreen.contains(NSEvent.mouseLocation)
    }

    // MARK: - Camera operations

    func applyOrbit(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.01
        cameraState.rotation.y -= deltaX * sensitivity
        cameraState.rotation.x -= deltaY * sensitivity
        cameraState.rotation.x = Swift.max(-.pi / 2 + 0.01, Swift.min(.pi / 2 - 0.01, cameraState.rotation.x))
    }

    func applyPan(deltaX: Float, deltaY: Float, scale: Float? = nil) {
        let panScale = scale ?? ViewportTuning.panScale(
            distance: cameraState.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        let rotX = simd_quatf(angle: cameraState.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: cameraState.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX
        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])
        cameraState.focus += (right * (-deltaX * panScale)) + (up * (deltaY * panScale))
    }

    func clampDistance(_ value: Float) -> Float {
        let minDist = ViewportTuning.minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        let maxDist: Float
        if let override = maxDistanceOverride {
            maxDist = Swift.max(override, minDist)
        } else {
            maxDist = ViewportTuning.maximumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
        }

        let epsilon: Float = 0.0001
        let clamped = Swift.min(Swift.max(value, minDist), maxDist)
        let edge: ClampEdge?

        if clamped <= minDist + epsilon {
            edge = .min
        } else if clamped >= maxDist - epsilon {
            edge = .max
        } else {
            edge = nil
        }

        if edge != lastClampedEdge {
            if edge != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            lastClampedEdge = edge
        }
        return clamped
    }

    private func publishState() {
        onCameraStateChanged?(cameraState)
    }
}

// MARK: - ViewModifier (thin shell)

public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    let metersPerUnit: Double
    let maxDistanceOverride: Float?
    let navigationMapping: RealityKitNavigationMapping
    var onPick: ((CGPoint, CGSize) -> Void)?

    @State private var controller = ArcballEventController()
    @State private var startDistance: Float?
    @State private var previousOrbitValue: DragGesture.Value?
    @State private var previousPanValue: DragGesture.Value?

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        metersPerUnit: Double = 1.0,
        maxDistance: Float? = nil,
        navigationMapping: RealityKitNavigationMapping = .apple,
        onPick: ((CGPoint, CGSize) -> Void)? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.maxDistanceOverride = maxDistance
        self.navigationMapping = navigationMapping
        self.onPick = onPick
    }

    public func body(content: Content) -> some View {
        let orbitDrag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                handleOrbitDrag(value)
                previousOrbitValue = value
            }
            .onEnded { _ in
                startDistance = nil
                previousOrbitValue = nil
            }

        let panDrag = DragGesture(minimumDistance: 1)
            .modifiers(.option)
            .onChanged { value in
                handlePanDrag(value)
                previousPanValue = value
            }
            .onEnded { _ in
                startDistance = nil
                previousPanValue = nil
            }

        let magnifyGesture = MagnificationGesture()
            .onChanged { value in
                handleMagnification(value)
            }
            .onEnded { _ in
                startDistance = nil
            }

        modifiedContent(
            content: content,
            orbitDrag: orbitDrag,
            panDrag: panDrag,
            magnifyGesture: magnifyGesture
        )
        .background(EventRegionView { view in
            controller.eventRegionView = view
        })
        .onAppear {
            syncController()
            controller.onCameraStateChanged = { newState in
                state = newState
            }
            controller.installMonitors()
        }
        .onChange(of: navigationMapping) { _, _ in syncController() }
        .onChange(of: sceneBounds) { _, _ in syncController() }
        .onChange(of: metersPerUnit) { _, _ in syncController() }
        .onChange(of: state) { _, newState in
            controller.cameraState = newState
        }
        .onDisappear {
            controller.tearDown()
        }
    }

    private func syncController() {
        controller.navigationMapping = navigationMapping
        controller.sceneBounds = sceneBounds
        controller.metersPerUnit = metersPerUnit
        controller.maxDistanceOverride = maxDistanceOverride
        controller.cameraState = state
        controller.onPick = onPick
    }

    @ViewBuilder
    private func modifiedContent<BodyContent: View, Orbit: Gesture, Pan: Gesture, Magnify: Gesture>(
        content: BodyContent,
        orbitDrag: Orbit,
        panDrag: Pan,
        magnifyGesture: Magnify
    ) -> some View {
        if navigationMapping.useSwiftUIGestures {
            content
                .gesture(orbitDrag)
                .gesture(panDrag)
                .simultaneousGesture(magnifyGesture)
        } else {
            content
                .simultaneousGesture(magnifyGesture)
        }
    }

    // MARK: - SwiftUI gesture handlers (use controller for shared logic)

    private func handleOrbitDrag(_ value: DragGesture.Value) {
        let deltaX = Float(value.translation.width - (previousOrbitValue?.translation.width ?? 0))
        let deltaY = Float(value.translation.height - (previousOrbitValue?.translation.height ?? 0))
        controller.applyOrbit(deltaX: deltaX, deltaY: deltaY)
        state = controller.cameraState
    }

    private func handlePanDrag(_ value: DragGesture.Value) {
        let deltaX = Float(value.translation.width - (previousPanValue?.translation.width ?? 0))
        let deltaY = Float(value.translation.height - (previousPanValue?.translation.height ?? 0))
        let scale = ViewportTuning.panScale(
            distance: state.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        controller.applyPan(deltaX: deltaX, deltaY: -deltaY, scale: scale)
        state = controller.cameraState
    }

    private func handleMagnification(_ magnification: CGFloat) {
        if startDistance == nil { startDistance = state.distance }
        guard let start = startDistance else { return }
        guard magnification > 0 else { return }
        let effective = controller.navigationMapping.invertZoomDirection
            ? 1.0 / magnification
            : magnification
        let newDistance = start / Float(effective)
        controller.cameraState.distance = controller.clampDistance(newDistance)
        state = controller.cameraState
    }
}
#else
@MainActor
final class ArcballTouchController: ObservableObject {
    var navigationMapping: RealityKitNavigationMapping = .touchpad
    var cameraState: ArcballCameraState = .init()
    var sceneBounds: SceneBounds = .init()
    var metersPerUnit: Double = 1.0
    var maxDistanceOverride: Float?
    var onCameraStateChanged: ((ArcballCameraState) -> Void)?
    var onPick: ((CGPoint, CGSize) -> Void)?

    private var startDistance: Float?
    private var lastClampedEdge: ClampEdge?
    private var activeGestureCount: Int = 0

    // Momentum
    private var orbitVelocity: CGPoint = .zero
    private var panVelocity: CGPoint = .zero
    private var displayLink: CADisplayLink?
    private var lastDisplayLinkTimestamp: CFTimeInterval = 0

    private enum ClampEdge {
        case min
        case max
    }

    private let clampEpsilon: Float = 0.0001

    var isInteracting: Bool { activeGestureCount > 0 || displayLink != nil }

    private var minDistance: Float {
        ViewportTuning.minimumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    private var maxDistanceValue: Float {
        if let override = maxDistanceOverride {
            return Swift.max(override, minDistance)
        }
        return ViewportTuning.maximumDistance(sceneBounds: sceneBounds, metersPerUnit: metersPerUnit)
    }

    func handleTap(at location: CGPoint, in size: CGSize) {
        touchGestureLogger.debug("tap at \(location.x, privacy: .public),\(location.y, privacy: .public)")
        onPick?(location, size)
    }

    func handleOrbitPan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        switch gesture.state {
        case .began:
            stopMomentum()
            activeGestureCount += 1
            gesture.setTranslation(.zero, in: view)
            let location = gesture.location(in: view)
            touchGestureLogger.debug("orbit began at \(location.x, privacy: .public),\(location.y, privacy: .public)")
        case .changed:
            let translation = gesture.translation(in: view)
            let deltaX = Float(translation.x)
            let deltaY = Float(translation.y)
            applyOrbit(deltaX: deltaX, deltaY: deltaY)
            gesture.setTranslation(.zero, in: view)
            publishState()
        case .ended:
            activeGestureCount = Swift.max(0, activeGestureCount - 1)
            let v = gesture.velocity(in: view)
            touchGestureLogger.debug("orbit ended velocity=\(v.x, privacy: .public),\(v.y, privacy: .public)")
            startOrbitMomentum(velocity: v)
        case .cancelled, .failed:
            activeGestureCount = Swift.max(0, activeGestureCount - 1)
            touchGestureLogger.debug("orbit cancelled/failed")
        default:
            break
        }
    }

    func handlePan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        switch gesture.state {
        case .began:
            stopMomentum()
            activeGestureCount += 1
            gesture.setTranslation(.zero, in: view)
            let location = gesture.location(in: view)
            touchGestureLogger.debug("pan began at \(location.x, privacy: .public),\(location.y, privacy: .public)")
        case .changed:
            let multiplier: Float = 2.5
            let translation = gesture.translation(in: view)
            let deltaX = Float(translation.x)
            let deltaY = Float(translation.y)
            let scrollInvert: Float = navigationMapping.invertScrollDirection ? -1 : 1
            applyPan(
                deltaX: deltaX * multiplier * scrollInvert,
                deltaY: deltaY * multiplier * scrollInvert
            )
            gesture.setTranslation(.zero, in: view)
            publishState()
        case .ended:
            activeGestureCount = Swift.max(0, activeGestureCount - 1)
            let v = gesture.velocity(in: view)
            touchGestureLogger.debug("pan ended velocity=\(v.x, privacy: .public),\(v.y, privacy: .public)")
            startPanMomentum(velocity: v)
        case .cancelled, .failed:
            activeGestureCount = Swift.max(0, activeGestureCount - 1)
            touchGestureLogger.debug("pan cancelled/failed")
        default:
            break
        }
    }

    func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            stopMomentum()
            activeGestureCount += 1
            startDistance = cameraState.distance
            touchGestureLogger.debug("pinch began scale=\(gesture.scale, privacy: .public)")
        }
        if startDistance == nil { startDistance = cameraState.distance }
        guard let start = startDistance else { return }
        guard gesture.scale > 0 else { return }
        let effective = navigationMapping.invertZoomDirection
            ? 1.0 / gesture.scale
            : gesture.scale
        cameraState.distance = clampDistance(start / Float(effective))
        publishState()
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            startDistance = nil
            activeGestureCount = Swift.max(0, activeGestureCount - 1)
            touchGestureLogger.debug("pinch ended")
        }
    }

    // MARK: - Momentum

    private func startOrbitMomentum(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 50 else { return }
        orbitVelocity = velocity
        ensureDisplayLink()
    }

    private func startPanMomentum(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 50 else { return }
        panVelocity = velocity
        ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        lastDisplayLinkTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(decayStep(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        orbitVelocity = .zero
        panVelocity = .zero
    }

    @objc private func decayStep(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastDisplayLinkTimestamp == 0 ? 0.0 : Float(now - lastDisplayLinkTimestamp)
        lastDisplayLinkTimestamp = now
        guard dt > 0 else { return }

        // Exponential decay — half-life 0.25s gives a natural, QuickLook-style coast.
        let decayFactor = CGFloat(exp(-log(Float(2)) / 0.25 * dt))

        if orbitVelocity != .zero {
            applyOrbit(deltaX: Float(orbitVelocity.x) * dt, deltaY: Float(orbitVelocity.y) * dt)
            orbitVelocity.x *= decayFactor
            orbitVelocity.y *= decayFactor
            if hypot(orbitVelocity.x, orbitVelocity.y) < 20 { orbitVelocity = .zero }
        }

        if panVelocity != .zero {
            let multiplier: Float = 2.5
            let scrollInvert: Float = navigationMapping.invertScrollDirection ? -1 : 1
            applyPan(
                deltaX: Float(panVelocity.x) * dt * multiplier * scrollInvert,
                deltaY: Float(panVelocity.y) * dt * multiplier * scrollInvert
            )
            panVelocity.x *= decayFactor
            panVelocity.y *= decayFactor
            if hypot(panVelocity.x, panVelocity.y) < 20 { panVelocity = .zero }
        }

        publishState()

        if orbitVelocity == .zero && panVelocity == .zero {
            stopMomentum()
        }
    }

    private func publishState() {
        onCameraStateChanged?(cameraState)
    }

    private func clampDistance(_ value: Float) -> Float {
        let maxDistance = maxDistanceValue
        let clamped = Swift.min(Swift.max(value, minDistance), maxDistance)
        let edge: ClampEdge?

        if clamped <= minDistance + clampEpsilon {
            edge = .min
        } else if clamped >= maxDistance - clampEpsilon {
            edge = .max
        } else {
            edge = nil
        }

        if edge != lastClampedEdge {
            if edge != nil {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            lastClampedEdge = edge
        }

        return clamped
    }

    private func applyOrbit(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.01
        cameraState.rotation.y -= deltaX * sensitivity
        cameraState.rotation.x -= deltaY * sensitivity
        cameraState.rotation.x = Swift.max(-.pi / 2 + 0.01, Swift.min(.pi / 2 - 0.01, cameraState.rotation.x))
    }

    private func applyPan(deltaX: Float, deltaY: Float) {
        let scale = ViewportTuning.panScale(
            distance: cameraState.distance,
            sceneBounds: sceneBounds,
            metersPerUnit: metersPerUnit
        )
        let rotX = simd_quatf(angle: cameraState.rotation.x, axis: [1, 0, 0])
        let rotY = simd_quatf(angle: cameraState.rotation.y, axis: [0, 1, 0])
        let orientation = rotY * rotX

        let right = orientation.act([1, 0, 0])
        let up = orientation.act([0, 1, 0])

        cameraState.focus += (right * (-deltaX * scale)) + (up * (deltaY * scale))
    }
}

private struct ArcballTouchInputOverlay: UIViewRepresentable {
    @ObservedObject var controller: ArcballTouchController

    func makeUIView(context: Context) -> ArcballTouchInputView {
        let view = ArcballTouchInputView()
        view.controller = controller
        return view
    }

    func updateUIView(_ uiView: ArcballTouchInputView, context: Context) {
        uiView.controller = controller
    }
}

private final class ArcballTouchInputView: UIView, UIGestureRecognizerDelegate {
    weak var controller: ArcballTouchController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        setupGestures()
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let orbitPan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbitPan.minimumNumberOfTouches = 1
        orbitPan.maximumNumberOfTouches = 1
        orbitPan.delegate = self
        addGestureRecognizer(orbitPan)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        tap.require(toFail: orbitPan)
        tap.require(toFail: pan)
        tap.require(toFail: pinch)
    }

    @objc
    private func handleTap(_ gesture: UITapGestureRecognizer) {
        controller?.handleTap(at: gesture.location(in: self), in: bounds.size)
    }

    @objc
    private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        controller?.handleOrbitPan(gesture, in: self)
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        controller?.handlePan(gesture, in: self)
    }

    @objc
    private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        controller?.handlePinch(gesture)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Two-finger pan + pinch can run together — matches QuickLook / Maps behaviour.
        let isPan = gestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPanGestureRecognizer
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        return isPan && isPinch
    }
}

public struct ArcballCameraControls: ViewModifier {
    @Binding var state: ArcballCameraState
    let sceneBounds: SceneBounds
    let metersPerUnit: Double
    let maxDistanceOverride: Float?
    let navigationMapping: RealityKitNavigationMapping
    var onPick: ((CGPoint, CGSize) -> Void)?

    @State private var controller = ArcballTouchController()

    public init(
        state: Binding<ArcballCameraState>,
        sceneBounds: SceneBounds,
        metersPerUnit: Double = 1.0,
        maxDistance: Float? = nil,
        navigationMapping: RealityKitNavigationMapping = .touchpad,
        onPick: ((CGPoint, CGSize) -> Void)? = nil
    ) {
        self._state = state
        self.sceneBounds = sceneBounds
        self.metersPerUnit = metersPerUnit
        self.maxDistanceOverride = maxDistance
        self.navigationMapping = navigationMapping
        self.onPick = onPick
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ArcballTouchInputOverlay(controller: controller)
            }
            .onAppear {
                syncController()
                controller.onCameraStateChanged = { newState in
                    state = newState
                }
            }
            .onChange(of: navigationMapping) { _, _ in syncController() }
            .onChange(of: sceneBounds) { _, _ in syncController() }
            .onChange(of: metersPerUnit) { _, _ in syncController() }
            .onChange(of: state) { _, newState in
                guard !controller.isInteracting else { return }
                controller.cameraState = newState
            }
    }

    private func syncController() {
        controller.navigationMapping = navigationMapping
        controller.sceneBounds = sceneBounds
        controller.metersPerUnit = metersPerUnit
        controller.maxDistanceOverride = maxDistanceOverride
        controller.cameraState = state
        controller.onPick = onPick
    }
}
#endif
