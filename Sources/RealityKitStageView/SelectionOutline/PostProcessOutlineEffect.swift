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
/// colour (the renderer only keeps resolved RGBA) and pending viewport
/// captures, handed from @MainActor to the render callback.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
final class OutlineEffectStorage: @unchecked Sendable {
    struct PendingCapture {
        let colorSpace: CGColorSpace
        let onComplete: @Sendable (Result<CGImage, Error>) -> Void
    }

    private let lock = NSLock()
    private var _color: Color
    private var _pendingCaptures: [PendingCapture] = []

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

    /// Queues a capture. Every capture queued before the next frame receives
    /// that frame.
    func enqueueCapture(_ capture: PendingCapture) {
        lock.withLock { _pendingCaptures.append(capture) }
    }

    func takePendingCaptures() -> [PendingCapture] {
        lock.withLock {
            let captures = _pendingCaptures
            _pendingCaptures = []
            return captures
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
/// copy is what every copy reads and draws with.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct PostProcessOutlineEffect: PostProcessEffect {

    private let renderer: OutlineRenderer
    private let storage: OutlineEffectStorage

    /// Outline colour. Defaults to the same cyan as `OutlineConfiguration`.
    public var color: Color {
        get { storage.color }
        nonmutating set {
            let renderer = renderer
            storage.setColor(newValue) { renderer.color = Self.rgba(from: $0) }
        }
    }

    /// Outline width in screen pixels (0...`OutlineRenderer.maxRadius`).
    public var radius: Int {
        get { renderer.radius }
        nonmutating set { renderer.radius = newValue }
    }

    /// Prefer renderable child meshes over the selected entity's own mesh.
    ///
    /// USDStageComponent can attach aggregate meshes to parent prim entities whose
    /// extracted vertices don't match the displayed child renderables. Keeping this
    /// off by default preserves StageView's historical "selected entity mesh wins"
    /// behavior for regular RealityKit imports.
    public var prefersChildMeshes: Bool {
        get { renderer.meshSelection == .preferDescendants }
        nonmutating set { renderer.meshSelection = newValue ? .preferDescendants : .nearestMeshes }
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
        storage.enqueueCapture(.init(colorSpace: colorSpace, onComplete: onComplete))
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
        enqueueFrameCaptureIfNeeded(
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

    /// Copies the finished frame into a capture-owned texture on the same
    /// command buffer, so RealityKit reusing its target for the next frame
    /// can't change what's read back.
    private func enqueueFrameCaptureIfNeeded(
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        device: any MTLDevice
    ) {
        let captures = storage.takePendingCaptures()
        guard !captures.isEmpty else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard
            let copy = device.makeTexture(descriptor: descriptor),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            captures.forEach { $0.onComplete(.failure(PostProcessFrameCaptureError.blitEncodingFailed)) }
            return
        }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()

        // Only this handler reads `copy`, after the GPU finished writing it.
        nonisolated(unsafe) let frame = copy
        commandBuffer.addCompletedHandler { buffer in
            guard buffer.status == .completed else {
                let error = buffer.error ?? PostProcessFrameCaptureError.imageCreationFailed
                captures.forEach { $0.onComplete(.failure(error)) }
                return
            }
            for capture in captures {
                self.completeFrameCaptureUsingCoreImage(
                    texture: frame,
                    device: device,
                    capture: capture
                )
            }
        }
    }

    private func completeFrameCaptureUsingCoreImage(
        texture: any MTLTexture,
        device: any MTLDevice,
        capture: OutlineEffectStorage.PendingCapture
    ) {
        let sourceColorSpace = sourceColorSpace(
            for: texture.pixelFormat,
            captureColorSpace: capture.colorSpace
        )
        let options: [CIImageOption: Any] = [
            .colorSpace: sourceColorSpace,
        ]
        guard let ciImage = CIImage(mtlTexture: texture, options: options) else {
            capture.onComplete(.failure(PostProcessFrameCaptureError.imageCreationFailed))
            return
        }

        let context = CIContext(mtlDevice: device)
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let uprightImage = ciImage
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(texture.height)))
        guard let cgImage = context.createCGImage(uprightImage, from: bounds, format: .RGBA8, colorSpace: capture.colorSpace) else {
            capture.onComplete(.failure(PostProcessFrameCaptureError.imageCreationFailed))
            return
        }

        capture.onComplete(.success(cgImage))
    }

    /// Interprets the source texture's pixels using the drawable's color
    /// primaries (inferred from `captureColorSpace`) rather than forcing an
    /// sRGB-primaries interpretation. On a P3 display the drawable stores
    /// P3-primaries values; treating them as sRGB would cause Core Image to
    /// apply an unnecessary gamut conversion that visibly darkens the output.
    ///
    /// `_srgb` formats are decoded to linear by the GPU when Core Image reads
    /// them, so they get the *linear* variant of the colour space. Labelling
    /// them with a gamma-encoded space made captures read darker than the
    /// on-screen viewport.
    private func sourceColorSpace(
        for pixelFormat: MTLPixelFormat,
        captureColorSpace: CGColorSpace
    ) -> CGColorSpace {
        let usesP3 = captureColorSpace.name == CGColorSpace.displayP3
            || captureColorSpace.name == CGColorSpace.extendedDisplayP3
            || captureColorSpace.name == CGColorSpace.extendedLinearDisplayP3
        switch pixelFormat {
        case .bgra10_xr_srgb, .bgr10_xr_srgb, .bgra8Unorm_srgb, .rgba8Unorm_srgb:
            if usesP3, let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
                return p3
            }
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        case .bgra10_xr, .bgr10_xr:
            if usesP3, let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
                return p3
            }
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        default:
            return captureColorSpace
        }
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
private enum PostProcessFrameCaptureError: LocalizedError {
    case blitEncodingFailed
    case bufferAllocationFailed
    case imageCreationFailed
    case providerCreationFailed
    case unsupportedPixelFormat(MTLPixelFormat)

    var errorDescription: String? {
        switch self {
        case .blitEncodingFailed:
            return "Failed to encode the GPU readback for viewport capture."
        case .bufferAllocationFailed:
            return "Failed to allocate GPU readback storage for viewport capture."
        case .imageCreationFailed:
            return "Failed to construct an image from the captured viewport buffer."
        case .providerCreationFailed:
            return "Failed to prepare the captured viewport data for export."
        case let .unsupportedPixelFormat(pixelFormat):
            return "Viewport capture does not support pixel format \(pixelFormat.rawValue)."
        }
    }
}
