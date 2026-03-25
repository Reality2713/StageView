import Metal
import OSLog
import RealityKit
import SwiftUI
import simd

private let outlineLogger = Logger(subsystem: "RealityKitStageView", category: "PostProcessOutline")

// MARK: - Internal State

/// Thread-safe reference type that holds all mutable Metal state and pending
/// mesh data. Shared between @MainActor call sites and the nonisolated
/// PostProcessEffect callbacks via @unchecked Sendable.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
final class OutlineRenderState: @unchecked Sendable {

    // MARK: Pending mesh data

    struct PendingEntry {
        /// Packed xyz float positions (stride 12 bytes).
        let positions: [Float]
        let indices: [UInt8]
        let indexCount: Int
        let indexType: MTLIndexType
        let modelMatrix: simd_float4x4
    }

    private let lock = NSLock()
    private var _pending: [PendingEntry]? = nil

    var pending: [PendingEntry]? {
        get { lock.withLock { _pending } }
        set { lock.withLock { _pending = newValue } }
    }

    // MARK: Compiled Metal state

    var device: (any MTLDevice)?
    var maskPipeline: (any MTLRenderPipelineState)?
    var dilatePipeline: (any MTLComputePipelineState)?
    var compositePipeline: (any MTLComputePipelineState)?
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var didLogPrepare = false
    var didLogFirstPostProcess = false

    // MARK: Resolved mesh entries (only accessed from postProcess)

    struct MeshEntry {
        let vertexBuffer: any MTLBuffer
        let indexBuffer: any MTLBuffer
        let indexCount: Int
        let indexType: MTLIndexType
        let modelMatrix: simd_float4x4
    }

    var meshEntries: [MeshEntry] = []

    // MARK: Pipeline setup

    func preparePipelines(device: any MTLDevice) {
        self.device = device

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            return
        }

        let maskDesc = MTLRenderPipelineDescriptor()
        maskDesc.vertexFunction = library.makeFunction(name: "outlineMaskVertex")
        maskDesc.fragmentFunction = library.makeFunction(name: "outlineMaskFragment")
        maskDesc.colorAttachments[0].pixelFormat = .r8Unorm
        maskDesc.depthAttachmentPixelFormat = .depth32Float

        // Packed float3 positions: format=float3, offset=0, stride=12.
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = 12
        maskDesc.vertexDescriptor = vd

        maskPipeline = try? device.makeRenderPipelineState(descriptor: maskDesc)

        guard
            let dilateFunc = library.makeFunction(name: "outlineDilate"),
            let compositeFunc = library.makeFunction(name: "outlineComposite")
        else { return }

        dilatePipeline = try? device.makeComputePipelineState(function: dilateFunc)
        compositePipeline = try? device.makeComputePipelineState(function: compositeFunc)
    }

    // MARK: Buffer creation from pending entries (called inside postProcess)

    func flushPending(device: any MTLDevice) {
        guard let entries = pending else { return }
        pending = nil

        meshEntries = entries.compactMap { entry in
            guard
                let vb = device.makeBuffer(
                    bytes: entry.positions,
                    length: entry.positions.count * MemoryLayout<Float>.size,
                    options: .storageModeShared
                ),
                let ib = device.makeBuffer(
                    bytes: entry.indices,
                    length: entry.indices.count,
                    options: .storageModeShared
                )
            else { return nil }

            return MeshEntry(
                vertexBuffer: vb,
                indexBuffer: ib,
                indexCount: entry.indexCount,
                indexType: entry.indexType,
                modelMatrix: entry.modelMatrix
            )
        }
    }
}

// MARK: - Public Effect

/// A `PostProcessEffect` that renders a pixel-perfect, scale-independent
/// selection outline using a three-pass Metal pipeline:
///
/// 1. **Mask pass** — renders the selected mesh(es) silhouette into an R8 texture.
/// 2. **Dilation pass** — expands the mask by `radius` pixels (compute kernel).
/// 3. **Composite pass** — blends the outline colour over the source frame (compute kernel).
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct PostProcessOutlineEffect: PostProcessEffect {

    private let state = OutlineRenderState()

    /// Outline colour. Defaults to the same cyan as `OutlineConfiguration`.
    public var color: Color

    /// Outline width in screen pixels.
    public var radius: Int

    public init(color: Color = .cyan, radius: Int = 2) {
        self.color = color
        self.radius = radius
    }

    // MARK: Selection API

    /// Sets the selected entity. Walks the subtree collecting every
    /// `ModelComponent` mesh and queues the packed position data for GPU upload
    /// on the next `postProcess` call.
    ///
    /// Pass `nil` to clear the selection.
    @MainActor
    public func setSelection(_ entity: Entity?) {
        guard let entity else {
            state.pending = []
            return
        }
        var entries: [OutlineRenderState.PendingEntry] = []
        collectSelectionMeshEntries(from: entity, into: &entries)
        state.pending = entries
    }

    @MainActor
    private func collectSelectionMeshEntries(
        from entity: Entity,
        into entries: inout [OutlineRenderState.PendingEntry]
    ) {
        if appendMeshEntryIfAvailable(from: entity, into: &entries) {
            // If the selected entity already owns a concrete mesh, outline that
            // mesh only. Descending into every child tends to explode the
            // selection to the whole imported subtree for material-group nodes.
            return
        }

        for child in entity.children {
            collectSelectionMeshEntries(from: child, into: &entries)
        }
    }

    @MainActor
    private func appendMeshEntryIfAvailable(
        from entity: Entity,
        into entries: inout [OutlineRenderState.PendingEntry]
    ) -> Bool {
        guard let model = entity.components[ModelComponent.self] else {
            outlineLogger.debug("Post-process mesh extraction skipped for '\(entity.name, privacy: .public)': no ModelComponent")
            return false
        }

        let noRef: Entity? = nil
        let worldTransform = entity.transformMatrix(relativeTo: noRef)

        let contentEntries = makePendingEntries(
            from: model.mesh.contents,
            entityWorldTransform: worldTransform
        )
        if contentEntries.isEmpty == false {
            entries.append(contentsOf: contentEntries)
            outlineLogger.debug(
                "Post-process mesh extraction for '\(entity.name, privacy: .public)' used MeshResource.contents with \(contentEntries.count, privacy: .public) entries"
            )
            return true
        }

        if let lowLevel = model.mesh.lowLevelMesh,
           let entry = makePendingEntry(mesh: lowLevel, worldTransform: worldTransform) {
            entries.append(entry)
            outlineLogger.debug(
                "Post-process mesh extraction for '\(entity.name, privacy: .public)' used lowLevelMesh"
            )
            return true
        }

        outlineLogger.info(
            "Post-process mesh extraction failed for '\(entity.name, privacy: .public)': ModelComponent present but neither MeshResource.contents nor lowLevelMesh produced entries"
        )
        return false
    }

    @MainActor
    private func makePendingEntry(
        mesh: LowLevelMesh,
        worldTransform: simd_float4x4
    ) -> OutlineRenderState.PendingEntry? {
        let descriptor = mesh.descriptor

        guard let posAttr = descriptor.vertexAttributes.first(where: { $0.semantic == .position })
        else { return nil }

        let layoutIndex = posAttr.layoutIndex
        let stride = descriptor.vertexLayouts[layoutIndex].bufferStride
        let posOffset = posAttr.offset

        // Extract packed xyz floats, handling any interleaved vertex layout.
        var positions: [Float] = []
        mesh.withUnsafeBytes(bufferIndex: layoutIndex) { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let vertexCount = rawBytes.count / stride
            positions.reserveCapacity(vertexCount * 3)
            for i in 0..<vertexCount {
                let base = i * stride + posOffset
                var x: Float = 0, y: Float = 0, z: Float = 0
                withUnsafeMutableBytes(of: &x) { $0.copyBytes(from: bytes[base ..< base + 4]) }
                withUnsafeMutableBytes(of: &y) { $0.copyBytes(from: bytes[(base + 4) ..< (base + 8)]) }
                withUnsafeMutableBytes(of: &z) { $0.copyBytes(from: bytes[(base + 8) ..< (base + 12)]) }
                positions.append(x)
                positions.append(y)
                positions.append(z)
            }
        }

        var indexBytes: [UInt8] = []
        mesh.withUnsafeIndices { rawBytes in
            indexBytes = Array(rawBytes)
        }

        let indexType = descriptor.indexType
        let indexCount: Int
        switch indexType {
        case .uint32: indexCount = indexBytes.count / MemoryLayout<UInt32>.size
        case .uint16: indexCount = indexBytes.count / MemoryLayout<UInt16>.size
        @unknown default: return nil
        }

        guard !positions.isEmpty, indexCount > 0 else { return nil }

        return .init(
            positions: positions,
            indices: indexBytes,
            indexCount: indexCount,
            indexType: indexType,
            modelMatrix: worldTransform
        )
    }

    @MainActor
    private func makePendingEntries(
        from contents: MeshResource.Contents,
        entityWorldTransform: simd_float4x4
    ) -> [OutlineRenderState.PendingEntry] {
        let modelsByID = Dictionary(uniqueKeysWithValues: contents.models.map { ($0.id, $0) })
        let instances = Array(contents.instances)

        if instances.isEmpty {
            return contents.models.flatMap { model in
                makePendingEntries(from: model, worldTransform: entityWorldTransform)
            }
        }

        return instances.flatMap { instance -> [OutlineRenderState.PendingEntry] in
            guard let model = modelsByID[instance.model] else { return [] }
            let worldTransform = simd_mul(entityWorldTransform, instance.transform)
            return makePendingEntries(from: model, worldTransform: worldTransform)
        }
    }

    @MainActor
    private func makePendingEntries(
        from model: MeshResource.Model,
        worldTransform: simd_float4x4
    ) -> [OutlineRenderState.PendingEntry] {
        model.parts.compactMap { part in
            makePendingEntry(from: part, worldTransform: worldTransform)
        }
    }

    @MainActor
    private func makePendingEntry(
        from part: MeshResource.Part,
        worldTransform: simd_float4x4
    ) -> OutlineRenderState.PendingEntry? {
        guard let triangleIndices = part.triangleIndices?.elements, triangleIndices.isEmpty == false else {
            return nil
        }

        let positions = part.positions.elements
        guard positions.isEmpty == false else { return nil }

        let packedPositions = positions.flatMap { [$0.x, $0.y, $0.z] }
        let indexBytes = triangleIndices.withUnsafeBytes { Array($0) }

        return .init(
            positions: packedPositions,
            indices: indexBytes,
            indexCount: triangleIndices.count,
            indexType: .uint32,
            modelMatrix: worldTransform
        )
    }

    // MARK: PostProcessEffect

    public mutating func prepare(for device: any MTLDevice) {
        state.preparePipelines(device: device)
        if state.didLogPrepare == false {
            state.didLogPrepare = true
            outlineLogger.info("Post-process outline prepared on device '\(device.name, privacy: .public)'")
        }
    }

    public mutating func setViewMatrix(_ viewMatrix: simd_float4x4) {
        state.viewMatrix = viewMatrix
    }

    public mutating func postProcess(
        context: borrowing PostProcessEffectContext<any MTLCommandBuffer>
    ) {
        let device = context.device
        let textureWidth = context.sourceColorTexture.width
        let textureHeight = context.sourceColorTexture.height

        state.flushPending(device: device)

        if state.didLogFirstPostProcess == false {
            state.didLogFirstPostProcess = true
            let meshEntryCount = state.meshEntries.count
            outlineLogger.info(
                "Post-process outline pass running with \(meshEntryCount, privacy: .public) mesh entries at \(textureWidth, privacy: .public)x\(textureHeight, privacy: .public)"
            )
        }

        guard
            !state.meshEntries.isEmpty,
            let maskPipeline = state.maskPipeline,
            let dilatePipeline = state.dilatePipeline,
            let compositePipeline = state.compositePipeline
        else {
            passThrough(context: context)
            return
        }

        let w = textureWidth
        let h = textureHeight
        let cb = context.commandBuffer

        guard
            let maskTex  = makeSingleChannelTexture(device: device, width: w, height: h,
                                                     usage: [.renderTarget, .shaderRead]),
            let depthTex = makeDepthTexture(device: device, width: w, height: h),
            let edgeTex  = makeSingleChannelTexture(device: device, width: w, height: h,
                                                     usage: [.shaderRead, .shaderWrite])
        else { return }

        // Pass 1 — render mesh silhouettes into the mask.
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture    = maskTex
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.depthAttachment.texture         = depthTex
        rpd.depthAttachment.loadAction      = .clear
        rpd.depthAttachment.storeAction     = .dontCare
        rpd.depthAttachment.clearDepth      = 1.0

        guard let renc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        renc.setRenderPipelineState(maskPipeline)
        for entry in state.meshEntries {
            var mvp = context.projection * state.viewMatrix * entry.modelMatrix
            renc.setVertexBuffer(entry.vertexBuffer, offset: 0, index: 0)
            renc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 1)
            renc.drawIndexedPrimitives(
                type: .triangle,
                indexCount: entry.indexCount,
                indexType: entry.indexType,
                indexBuffer: entry.indexBuffer,
                indexBufferOffset: 0
            )
        }
        renc.endEncoding()

        // Pass 2 — dilate mask into the edge ring.
        guard let cenc1 = cb.makeComputeCommandEncoder() else { return }
        cenc1.setComputePipelineState(dilatePipeline)
        cenc1.setTexture(maskTex, index: 0)
        cenc1.setTexture(edgeTex, index: 1)
        var r = Int32(radius)
        cenc1.setBytes(&r, length: MemoryLayout<Int32>.size, index: 0)
        dispatchFullscreen(encoder: cenc1, pipeline: dilatePipeline, width: w, height: h)
        cenc1.endEncoding()

        // Pass 3 — composite outline colour over the source frame.
        guard let cenc2 = cb.makeComputeCommandEncoder() else { return }
        cenc2.setComputePipelineState(compositePipeline)
        cenc2.setTexture(context.sourceColorTexture, index: 0)
        cenc2.setTexture(edgeTex, index: 1)
        cenc2.setTexture(context.targetColorTexture, index: 2)
        var c = resolvedColor
        cenc2.setBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        dispatchFullscreen(encoder: cenc2, pipeline: compositePipeline, width: w, height: h)
        cenc2.endEncoding()
    }

    // MARK: Helpers

    private var resolvedColor: SIMD4<Float> {
        let r = color.resolve(in: EnvironmentValues())
        return SIMD4<Float>(Float(r.red), Float(r.green), Float(r.blue), Float(r.opacity))
    }

    private func passThrough(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: context.sourceColorTexture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width:  context.sourceColorTexture.width,
                height: context.sourceColorTexture.height,
                depth:  1
            ),
            to: context.targetColorTexture,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    private func makeSingleChannelTexture(
        device: any MTLDevice, width: Int, height: Int, usage: MTLTextureUsage
    ) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func makeDepthTexture(
        device: any MTLDevice, width: Int, height: Int
    ) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = .renderTarget
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func dispatchFullscreen(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let tgs = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width:  (width  + tgs.width  - 1) / tgs.width,
            height: (height + tgs.height - 1) / tgs.height,
            depth:  1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tgs)
    }
}
