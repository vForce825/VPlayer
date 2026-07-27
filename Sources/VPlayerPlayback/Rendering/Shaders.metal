// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <metal_stdlib>
using namespace metal;

struct MetalGPUUniforms {
    float4 yuvColumn0;
    float4 yuvColumn1;
    float4 yuvColumn2;
    float4 range;
    float4 textureTransform;
};

struct RasterData {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex RasterData fullScreenVertex(
    uint vertexID [[vertex_id]],
    constant MetalGPUUniforms &uniforms [[buffer(0)]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 coordinates[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    RasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.textureCoordinate = uniforms.textureTransform.xy
        + coordinates[vertexID] * uniforms.textureTransform.zw;
    return output;
}

fragment float4 yuvFragment(
    RasterData input [[stage_in]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]],
    sampler videoSampler [[sampler(0)]],
    constant MetalGPUUniforms &uniforms [[buffer(0)]]) {
    const float normalization = uniforms.yuvColumn0.w == 0.0
        ? 1.0
        : uniforms.yuvColumn0.w;
    const float y = max(0.0, (lumaTexture.sample(videoSampler, input.textureCoordinate).r
        * normalization - uniforms.range.x) * uniforms.range.y);
    const float2 chroma = (chromaTexture.sample(videoSampler, input.textureCoordinate).rg
        * normalization - uniforms.range.zz) * uniforms.range.w;
    const float3x3 yuvMatrix = float3x3(
        uniforms.yuvColumn0.xyz,
        uniforms.yuvColumn1.xyz,
        uniforms.yuvColumn2.xyz
    );
    // Preserve the source transfer function. On tvOS, CAEDRMetadata is not
    // available for a linear floating-point presentation path; the CAMetalLayer
    // colorspace identifies this encoded signal as BT.709, HLG, or PQ and lets
    // the system/display apply the final device-dependent transfer mapping.
    const float3 rgb = max(yuvMatrix * float3(y, chroma.x, chroma.y), 0.0);
    return float4(rgb, 1.0);
}
