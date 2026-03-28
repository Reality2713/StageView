# Pixel-Perfect Selection Outlines in RealityKit

When you click an entity in a 3D viewport, the selection feedback has to be unambiguous. The outline needs to follow the actual shape of the mesh, not an approximation of it. Getting there in RealityKit required picking the right technique — there are several approaches and they fail in different ways.

---

## The Alternatives

### Bounding box

The simplest approach. RealityKit can draw an axis-aligned bounding box around any entity with no mesh access required.

`[CAPTURE: bounding box on a complex organic mesh — box floating well outside actual geometry]`

It works as a "something is selected" indicator on simple geometry. On anything with an irregular silhouette the box either clips the mesh or floats far away from it. It conveys location, not shape.

### Inverted hull

The classic DCC trick. Duplicate the mesh, flip face winding so only back-faces render, apply an unlit solid color, scale up slightly. The back-face shell protrudes just beyond the original mesh and forms an outline ring.

`[CAPTURE: inverted hull on a complex mesh — blob artifact at concavities]`

It works well on hard-surface models with convex geometry. It breaks on:

- **Concavities** — the scaled hull bleeds through concave areas, producing smear artifacts instead of a clean edge
- **Tiny models** — a fixed scale factor like `1.015` produces near-zero screen-space expansion. The outline disappears
- **Huge models** — the same factor produces a meters-thick shell
- **Non-uniform scale** — uniform hull expansion doesn't follow a stretched mesh correctly, outline is thicker on some axes

The scale problem is partially addressable by compensating for camera distance. But model size is a separate variable the technique has no good answer for.

`[CAPTURE: same model at tiny vs huge scale — hull breaking at both extremes, post-process holding]`

### Post-process outline

`[CAPTURE: post-process outline on the same complex mesh — clean pixel-perfect ring]`

Never touches the scene. Operates at screen resolution regardless of mesh complexity, model size, or poly count. The outline is always the same pixel width. This is the approach we used.

---

## How It Works

`PostProcessEffect` is a RealityKit protocol (macOS 26+, iOS 26+) that lets you inject Metal work between RealityKit's rendered frame and the display. You receive:

- `sourceColorTexture` — the frame as rendered by RealityKit
- `targetColorTexture` — where you write the final output
- `commandBuffer` — ready to encode into
- `projection` — the current projection matrix

The outline is three passes encoded into that command buffer before the frame is presented.

---

## Pass 1 — Silhouette Mask

Render the selected mesh's geometry into a single-channel `R8Unorm` texture. Every pixel covered by the mesh becomes white. The result is a binary silhouette at screen resolution.

`[CAPTURE: Metal debugger — mask texture, white silhouette on black]`

The vertex shader needs only two things: packed positions and an MVP matrix.

```metal
vertex float4 outlineMaskVertex(
    const device packed_float3* positions [[buffer(0)]],
    constant OutlineMaskUniforms& uniforms [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    return uniforms.mvp * float4(float3(positions[vid]), 1.0);
}

fragment float4 outlineMaskFragment(float4 position [[position]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}
```

No normals. No UVs. No materials. The mask pass only answers one question: which screen pixels are covered by this geometry?

A depth attachment is included so geometry occluded by other objects does not appear in the mask.

---

## Pass 2 — Dilation

Expand the mask outward by `radius` pixels. Pixels outside the mesh but within `radius` of the silhouette edge become `1.0`. Interior pixels are explicitly suppressed to `0.0`. The result is a ring at the silhouette boundary only.

`[CAPTURE: Metal debugger — edge texture, thin ring around the silhouette with suppressed interior]`

```metal
kernel void outlineDilate(
    texture2d<float, access::read>  maskTexture [[texture(0)]],
    texture2d<float, access::write> edgeTexture [[texture(1)]],
    constant int32_t&               radius      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (maskTexture.read(gid).r > 0.5) {
        edgeTexture.write(float4(0.0), gid);  // interior — suppress
        return;
    }
    bool nearMask = false;
    for (int dy = -radius; dy <= radius && !nearMask; ++dy)
        for (int dx = -radius; dx <= radius && !nearMask; ++dx) {
            if (dx*dx + dy*dy > radius*radius) continue;
            if (maskTexture.read(uint2(int(gid.x)+dx, int(gid.y)+dy)).r > 0.5)
                nearMask = true;
        }
    edgeTexture.write(float4(nearMask ? 1.0 : 0.0), gid);
}
```

---

## Pass 3 — Composite

Blend the outline color over the source frame wherever the edge ring is set. Write to the target texture.

`[CAPTURE: Metal debugger — final composite, outline over rendered scene]`

```metal
kernel void outlineComposite(
    texture2d<float, access::read>  sourceColor  [[texture(0)]],
    texture2d<float, access::read>  edgeMask     [[texture(1)]],
    texture2d<float, access::write> targetColor  [[texture(2)]],
    constant float4&                outlineColor [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 color = sourceColor.read(gid);
    if (edgeMask.read(gid).r > 0.5)
        color = mix(color, float4(outlineColor.rgb, 1.0), outlineColor.a);
    targetColor.write(color, gid);
}
```

The scene is rendered first by RealityKit, untouched. The outline is added afterward as a screen-space image operation.

---

## Getting Geometry Out of the Selected Entity

The mask pass needs packed `float3` positions, triangle indices, and the entity's world transform. That is all — nothing else is forwarded to the GPU.

For our loaded USD models, `MeshResource.contents` was the working extraction path. Each `MeshResource.Part` exposes typed positions and triangle indices directly:

```swift
let packedPositions = part.positions.elements.flatMap { [$0.x, $0.y, $0.z] }
let indexBytes = triangleIndices.withUnsafeBytes { Array($0) }
```

No buffer unwinding, no topology reconstruction. RealityKit is already exposing indexed mesh data at the CPU level. We confirmed this by instrumenting the extraction code — the runtime logs consistently showed `MeshResource.contents` producing entries for every loaded USD asset we tested.

### How much of the hierarchy to walk

Selecting a group node and collecting every `ModelComponent` in the subtree outlines the entire imported model. The practical rule: stop at the first entity that owns a concrete mesh.

```swift
func collectMeshEntries(from entity: Entity, into entries: inout [PendingEntry]) {
    if appendMeshEntryIfAvailable(from: entity, into: &entries) {
        return  // has a mesh — don't descend
    }
    for child in entity.children {
        collectMeshEntries(from: child, into: &entries)
    }
}
```

For leaf mesh nodes it stops immediately. For group/xform nodes it finds the first level of concrete geometry children.

---

## The Transform Stack

The mask aligns with the rendered object because the transform composition is correct:

```swift
mvp = projection * viewMatrix * modelMatrix
```

- `modelMatrix` — entity world transform from `entity.transformMatrix(relativeTo: nil)` at extraction time
- `viewMatrix` — camera transform inverse, updated every frame
- `projection` — from `PostProcessEffectContext`

Get any of these wrong and the mask is offset from the object — the outline appears displaced or at the wrong scale. This is the most common failure mode when first implementing the technique.

---

## The Offscreen Mask — What It Is and What It Costs

"Offscreen" means a texture that is never presented to the screen. It exists only as an intermediate render target for the duration of a single frame.

Two offscreen textures are created for each `postProcess` call:

- `maskTex` — `R8Unorm`, single channel, full screen resolution. Receives the silhouette render in Pass 1, read by the dilation kernel in Pass 2
- `edgeTex` — same format and size. Written by the dilation kernel, read by the composite kernel in Pass 3

Both are created with `.storageMode = .private` — GPU-private memory, never accessible from the CPU. This is the fastest storage mode available. There is no CPU/GPU synchronization cost and no memory copy involved.

A depth texture is also allocated for Pass 1 with `.storeAction = .dontCare`. That tells Metal the depth buffer does not need to be written back to memory after the pass completes. It is used only during rasterization for occlusion, then discarded. Metal can keep it in tile memory on Apple Silicon and never materialize it at all.

### What the GPU actually does

Pass 1 draws only the **selected mesh** — not the entire scene. Its cost scales with the selected geometry's triangle count, not the scene's total complexity. A highly detailed background has zero influence on the mask pass cost.

Passes 2 and 3 are compute kernels dispatched over the full screen resolution in `16×16` threadgroups. For a 2560×1600 display that is ~16,000 threadgroups. Pass 2 (dilation) does a circular neighbourhood search of `(2r+1)²` iterations per pixel — with the default `radius = 2` that is 25 iterations per pixel. These are simple texture reads with no branching beyond the early-exit on interior pixels.

### When nothing is selected

If nothing is selected, the three passes are skipped entirely and a blit copy runs instead:

```swift
blit.copy(from: context.sourceColorTexture, ..., to: context.targetColorTexture, ...)
```

No render pass, no compute dispatch, no offscreen textures. The overhead when idle is effectively zero.

### The one real cost

The textures are allocated fresh on every `postProcess` call. Allocating two full-resolution GPU textures per frame adds overhead that a production implementation would eliminate by caching them and only reallocating on viewport resize.

---

## Summary

Three passes, one `PostProcessEffect`, geometry extracted from `MeshResource.contents`:

1. Rasterize the selected mesh into an offscreen `R8Unorm` silhouette mask
2. Dilate the mask into a pixel-wide edge ring, suppressing the interior
3. Composite the outline color over the source frame

The scene is never mutated. The outline holds at any model size, poly count, or camera distance.
