// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <metal_stdlib>
using namespace metal;

struct MetalGPUUniforms {
    float4 yuvColumn0;
    float4 yuvColumn1;
    float4 yuvColumn2;
    float4 gamutColumn0;
    float4 gamutColumn1;
    float4 gamutColumn2;
    float4 range;
    float4 textureTransform;
    uint transferKind;
    uint applyGamutTransform;
    uint padding0;
    uint padding1;
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
    float3 rgb = max(yuvMatrix * float3(y, chroma.x, chroma.y), 0.0);

    if (uniforms.transferKind == 1) {
        rgb = select(
            rgb / 4.5,
            pow((rgb + 0.099) / 1.099, float3(1.0 / 0.45)),
            rgb >= 0.081
        );
    } else if (uniforms.transferKind == 2) {
        const float m1 = 2610.0 / 16384.0;
        const float m2 = 2523.0 / 32.0;
        const float c1 = 3424.0 / 4096.0;
        const float c2 = 2413.0 / 128.0;
        const float c3 = 2392.0 / 128.0;
        const float3 p = pow(rgb, float3(1.0 / m2));
        rgb = pow(max(p - c1, 0.0) / max(c2 - c3 * p, 0.000001), float3(1.0 / m1)) * 100.0;
    } else if (uniforms.transferKind == 3) {
        const float a = 0.17883277;
        const float b = 0.28466892;
        const float c = 0.55991073;
        const float3 scene = select(
            (rgb * rgb) / 3.0,
            (exp((rgb - c) / a) + b) / 12.0,
            rgb > 0.5
        );
        const float3 lumaWeights = uniforms.applyGamutTransform != 0
            ? float3(0.2126, 0.7152, 0.0722)
            : float3(0.2627, 0.6780, 0.0593);
        const float sceneLuma = dot(scene, lumaWeights);
        rgb = scene * pow(max(sceneLuma, 0.000001), 0.2) * 10.0;
    }

    if (uniforms.applyGamutTransform != 0) {
        const float3x3 gamut = float3x3(
            uniforms.gamutColumn0.xyz,
            uniforms.gamutColumn1.xyz,
            uniforms.gamutColumn2.xyz
        );
        rgb = gamut * rgb;
    }
    return float4(rgb, 1.0);
}
