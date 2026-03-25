#include <metal_stdlib>
using namespace metal;

// MARK: - Selection Mask Render

/// Per-draw uniforms for the mask render pass.
struct OutlineMaskUniforms {
    float4x4 mvp;
};

/// Vertex shader — expects packed float3 positions at buffer(0), stride 12.
/// buffer(1) holds OutlineMaskUniforms.
vertex float4 outlineMaskVertex(
    const device packed_float3* positions [[buffer(0)]],
    constant OutlineMaskUniforms& uniforms [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    return uniforms.mvp * float4(float3(positions[vid]), 1.0);
}

/// Fragment shader — writes solid white into the single-channel mask texture.
fragment float4 outlineMaskFragment(float4 position [[position]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}

// MARK: - Dilation

/// Screen-space dilation kernel.
///
/// For each pixel *outside* the mask (r == 0) checks whether any pixel within
/// a circular neighbourhood of `radius` is inside the mask (r > 0.5). If so,
/// the output pixel is set to 1.0 — forming the outline ring.
/// Pixels already inside the mask are written as 0.0 so the outline only
/// appears around the silhouette edge, not over the interior.
kernel void outlineDilate(
    texture2d<float, access::read>  maskTexture  [[texture(0)]],
    texture2d<float, access::write> edgeTexture  [[texture(1)]],
    constant int32_t&               radius       [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint width  = maskTexture.get_width();
    const uint height = maskTexture.get_height();
    if (gid.x >= width || gid.y >= height) return;

    const float center = maskTexture.read(gid).r;

    // Interior pixels don't form part of the outline.
    if (center > 0.5) {
        edgeTexture.write(float4(0.0), gid);
        return;
    }

    // Search for a nearby masked pixel.
    bool nearMask = false;
    const int r = radius;
    for (int dy = -r; dy <= r && !nearMask; ++dy) {
        for (int dx = -r; dx <= r && !nearMask; ++dx) {
            if (dx * dx + dy * dy > r * r) continue;
            const int nx = int(gid.x) + dx;
            const int ny = int(gid.y) + dy;
            if (nx < 0 || ny < 0 || nx >= int(width) || ny >= int(height)) continue;
            if (maskTexture.read(uint2(nx, ny)).r > 0.5) nearMask = true;
        }
    }

    edgeTexture.write(float4(nearMask ? 1.0 : 0.0), gid);
}

// MARK: - Composite

/// Blends `outlineColor` over `sourceColor` wherever `edgeMask` is set,
/// writing the result to `targetColor`.
///
/// buffer(0): float4 outlineColor (RGBA)
kernel void outlineComposite(
    texture2d<float, access::read>  sourceColor  [[texture(0)]],
    texture2d<float, access::read>  edgeMask     [[texture(1)]],
    texture2d<float, access::write> targetColor  [[texture(2)]],
    constant float4&                outlineColor [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint width  = sourceColor.get_width();
    const uint height = sourceColor.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float4 color = sourceColor.read(gid);
    const float edge = edgeMask.read(gid).r;

    if (edge > 0.5) {
        color = mix(color, float4(outlineColor.rgb, 1.0), outlineColor.a);
    }

    targetColor.write(color, gid);
}
