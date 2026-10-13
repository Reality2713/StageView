import CoreGraphics
import CoreImage
import Foundation
import Metal

/// Viewport captures requested on the main actor and fulfilled on the render
/// thread from the next finished frame.
///
/// Fed by SelectionEffects' `frameHandler` (and, for the deprecated
/// `PostProcessOutlineEffect`, by that effect's `postProcess`).
final class ViewportFrameCapture: @unchecked Sendable {
    struct PendingCapture {
        let colorSpace: CGColorSpace
        let onComplete: @Sendable (Result<CGImage, Error>) -> Void
    }

    private let lock = NSLock()
    private var pendingCaptures: [PendingCapture] = []

    /// Queues a capture. Every capture queued before the next frame receives
    /// that frame.
    func request(
        colorSpace: CGColorSpace,
        onComplete: @escaping @Sendable (Result<CGImage, Error>) -> Void
    ) {
        lock.withLock { pendingCaptures.append(PendingCapture(colorSpace: colorSpace, onComplete: onComplete)) }
    }

    private func takePendingCaptures() -> [PendingCapture] {
        lock.withLock {
            let captures = pendingCaptures
            pendingCaptures = []
            return captures
        }
    }

    /// Copies the finished frame into a capture-owned texture on the same
    /// command buffer, so RealityKit reusing its target for the next frame
    /// can't change what's read back.
    func captureIfRequested(
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        device: any MTLDevice
    ) {
        let captures = takePendingCaptures()
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
        capture: PendingCapture
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
    /// them, and float formats store linear values, so both get the *linear*
    /// variant of the colour space. Labelling them with a gamma-encoded space
    /// made captures read darker than the on-screen viewport.
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
        case .bgra10_xr, .bgr10_xr, .rgba16Float, .rgba32Float:
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

enum PostProcessFrameCaptureError: LocalizedError {
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
