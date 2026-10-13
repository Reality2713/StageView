import CoreGraphics
import CoreImage
import Metal
import OSLog
import PostProcessOutline
import RealityKit
import SwiftUI
import simd

private let outlineLogger = Logger(subsystem: "RealityKitStageView", category: "PostProcessOutline")

// MARK: - Shared state

/// State shared by every copy of a `PostProcessOutlineEffect`: the outline
/// colour (the renderer only keeps resolved RGBA).
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
final class OutlineEffectStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var _color: Color

    init(color: Color) {
        _color = color
    }

    var color: Color {
        lock.withLock { _color }
    }

    /// Stores `color` and applies it to the renderer in one critical section,
    /// so concurrent setters can't leave the stored and drawn colours apart.
    func setColor(_ color: Color, apply: (Color) -> Void) {
        lock.withLock {
            _color = color
            apply(color)
        }
    }
}

// MARK: - Effect

/// StageView's post-process selection outline: the `PostProcessOutline`
/// package's `OutlineRenderer` plus viewport frame capture.
///
/// RealityView allows a single custom post-process effect, so viewport
/// capture (`requestFrameCapture`) reads the finished frame from this effect.
///
/// Copies share one renderer and one storage, so a setting changed through any
/// copy is what every copy reads and draws with. Setters are still `mutating`,
/// so writing through a `@State` property notifies SwiftUI as before.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
@available(*, deprecated, message: "Use SelectionEffects: call content.installSelectionEffects(camera:frameHandler:) in the RealityView make closure and add SelectionEffectComponent to the selected entity. StageView's .postProcessOutline style already does.")
public struct PostProcessOutlineEffect: PostProcessEffect {

    private let renderer: OutlineRenderer
    private let storage: OutlineEffectStorage
    private let frameCapture = ViewportFrameCapture()

    /// Outline colour. Defaults to the same cyan as `OutlineConfiguration`.
    public var color: Color {
        get { storage.color }
        set {
            let renderer = renderer
            storage.setColor(newValue) { renderer.color = Self.rgba(from: $0) }
        }
    }

    /// Outline width in screen pixels (0...`OutlineRenderer.maxRadius`).
    public var radius: Int {
        get { renderer.radius }
        set { renderer.radius = newValue }
    }

    /// Prefer renderable child meshes over the selected entity's own mesh.
    ///
    /// USDStageComponent can attach aggregate meshes to parent prim entities whose
    /// extracted vertices don't match the displayed child renderables. Keeping this
    /// off by default preserves StageView's historical "selected entity mesh wins"
    /// behavior for regular RealityKit imports.
    public var prefersChildMeshes: Bool {
        get { renderer.meshSelection == .preferDescendants }
        set { renderer.meshSelection = newValue ? .preferDescendants : .nearestMeshes }
    }

    public init(color: Color = .cyan, radius: Int = 2, prefersChildMeshes: Bool = false) {
        renderer = OutlineRenderer(color: Self.rgba(from: color), radius: radius)
        // Stage content can be edited in place (USD), so read meshes fresh on
        // every selection, as StageView always has.
        renderer.cachesGeometry = false
        renderer.meshSelection = prefersChildMeshes ? .preferDescendants : .nearestMeshes
        storage = OutlineEffectStorage(color: color)
    }

    @MainActor
    public func requestFrameCapture(
        colorSpace: CGColorSpace,
        onComplete: @escaping @Sendable (Result<CGImage, Error>) -> Void
    ) {
        frameCapture.request(colorSpace: colorSpace, onComplete: onComplete)
    }

    // MARK: Selection API

    /// Sets the selected entity, or clears the selection when `nil`.
    @MainActor
    public func setSelection(_ entity: Entity?) {
        renderer.setSelection(entity)
        if let entity {
            outlineLogger.debug("Post-process outline selection set to '\(entity.name, privacy: .public)'")
        }
    }

    /// Re-reads world transforms of the selected entities so moving entities
    /// stay outlined. Call alongside `setViewMatrix(_:)`.
    @MainActor
    public func updateTransforms() {
        renderer.updateTransforms()
    }

    // MARK: PostProcessEffect

    public func prepare(for device: any MTLDevice) {
        renderer.prepare(device: device)
        outlineLogger.info("Post-process outline prepared on device '\(device.name, privacy: .public)'")
    }

    public func setViewMatrix(_ viewMatrix: simd_float4x4) {
        renderer.setViewMatrix(viewMatrix)
    }

    public func postProcess(
        context: borrowing PostProcessEffectContext<any MTLCommandBuffer>
    ) {
        renderer.encode(
            device: context.device,
            commandBuffer: context.commandBuffer,
            source: context.sourceColorTexture,
            target: context.targetColorTexture,
            projection: context.projection
        )
        frameCapture.captureIfRequested(
            texture: context.targetColorTexture,
            commandBuffer: context.commandBuffer,
            device: context.device
        )
    }

    // MARK: Helpers

    private static func rgba(from color: Color) -> SIMD4<Float> {
        let r = color.resolve(in: EnvironmentValues())
        return SIMD4<Float>(Float(r.red), Float(r.green), Float(r.blue), Float(r.opacity))
    }
}
