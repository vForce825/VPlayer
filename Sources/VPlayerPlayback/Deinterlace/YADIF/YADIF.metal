// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <metal_stdlib>
using namespace metal;

struct YADIFKernelUniforms {
    uint outputIndex;
    uint topFieldFirst;
    uint spatialOnly;
};

// The component count is a compile-time property of the entry point rather than
// a uniform. Indexing a vector with a runtime value cannot stay in registers, so
// the compiler spills the whole texel to scratch memory and reads one lane back
// — once per sample, and a synthesized pixel takes two dozen samples.
template <typename Codes> struct PlaneCodec;

template <> struct PlaneCodec<int> {
    static inline int decode(float4 texel, bool tenBit) {
        float value = clamp(texel.x, 0.0f, 1.0f);
        return tenBit
            ? (int(round(value * 65535.0f)) >> 6)
            : int(round(value * 255.0f));
    }

    static inline float4 encode(int codes, bool tenBit) {
        float value = tenBit
            ? float(codes << 6) / 65535.0f
            : float(codes) / 255.0f;
        return float4(value, 0.0f, 0.0f, 1.0f);
    }
};

template <> struct PlaneCodec<int2> {
    static inline int2 decode(float4 texel, bool tenBit) {
        float2 value = clamp(texel.xy, 0.0f, 1.0f);
        return tenBit
            ? (int2(round(value * 65535.0f)) >> 6)
            : int2(round(value * 255.0f));
    }

    static inline float4 encode(int2 codes, bool tenBit) {
        float2 value = tenBit
            ? float2(codes << 6) / 65535.0f
            : float2(codes) / 255.0f;
        return float4(value.x, value.y, 0.0f, 1.0f);
    }
};

template <typename Codes, bool TenBit>
inline Codes sampleCodes(
    texture2d<float, access::read> image,
    int x,
    int y
) {
    int boundedX = clamp(x, 0, int(image.get_width()) - 1);
    int boundedY = clamp(y, 0, int(image.get_height()) - 1);
    return PlaneCodec<Codes>::decode(
        image.read(uint2(uint(boundedX), uint(boundedY))),
        TenBit
    );
}

// The spatial search only ever touches seven taps of the row above the missing
// line and seven of the row below it, but it revisits them along five candidate
// directions. Staging the fourteen in registers turns forty texture reads into
// fourteen without changing a single comparison.
template <typename Codes>
struct FieldWindow {
    Codes above[7];
    Codes below[7];
};

template <typename Codes, int Direction>
inline Codes directionalScore(thread const FieldWindow<Codes> &window) {
    return abs(window.above[2 + Direction] - window.below[2 - Direction])
        + abs(window.above[3 + Direction] - window.below[3 - Direction])
        + abs(window.above[4 + Direction] - window.below[4 - Direction]);
}

template <typename Codes, int Direction>
inline Codes directionalPrediction(thread const FieldWindow<Codes> &window) {
    return (window.above[3 + Direction] + window.below[3 - Direction]) >> 1;
}

// The scalar original returns early when the near direction does not improve on
// the running score, which also skips the far direction. Two components cannot
// share one branch, so the far candidate is scored unconditionally and masked
// out with a sentinel that no real score can beat.
template <typename Codes, int Sign>
inline void refineDirectionPair(
    thread const FieldWindow<Codes> &window,
    thread Codes &score,
    thread Codes &prediction
) {
    Codes nearScore = directionalScore<Codes, Sign>(window);
    Codes nearPrediction = directionalPrediction<Codes, Sign>(window);
    Codes farScore = directionalScore<Codes, Sign * 2>(window);
    Codes farPrediction = directionalPrediction<Codes, Sign * 2>(window);

    Codes bestScore = select(score, nearScore, nearScore < score);
    Codes bestPrediction = select(prediction, nearPrediction, nearScore < score);
    Codes maskedFarScore = select(Codes(0x7fffffff), farScore, nearScore < score);

    score = select(bestScore, farScore, maskedFarScore < bestScore);
    prediction = select(bestPrediction, farPrediction, maskedFarScore < bestScore);
}

template <typename Codes>
inline Codes spatialPrediction(
    thread const FieldWindow<Codes> &window,
    bool interior
) {
    Codes prediction = (window.above[3] + window.below[3]) >> 1;
    if (!interior) {
        return prediction;
    }
    Codes score = abs(window.above[2] - window.below[2])
        + abs(window.above[3] - window.below[3])
        + abs(window.above[4] - window.below[4])
        - Codes(1);
    refineDirectionPair<Codes, -1>(window, score, prediction);
    refineDirectionPair<Codes, 1>(window, score, prediction);
    return prediction;
}

template <typename Codes, bool TenBit>
inline Codes synthesize(
    texture2d<float, access::read> previous,
    texture2d<float, access::read> current,
    texture2d<float, access::read> next,
    thread const FieldWindow<Codes> &window,
    int x,
    int y,
    int aboveY,
    int belowY,
    int width,
    int height,
    constant YADIFKernelUniforms &uniforms
) {
    Codes prediction = spatialPrediction<Codes>(
        window,
        x >= 3 && x + 3 < width
    );
    if (uniforms.spatialOnly != 0) {
        return prediction;
    }

    bool firstOutput = uniforms.outputIndex == 0;
    texture2d<float, access::read> before = firstOutput ? previous : current;
    texture2d<float, access::read> after = firstOutput ? current : next;

    Codes temporalBefore = sampleCodes<Codes, TenBit>(before, x, y);
    Codes temporalAfter = sampleCodes<Codes, TenBit>(after, x, y);
    Codes center = (temporalBefore + temporalAfter) >> 1;
    Codes centerDifference = abs(temporalBefore - temporalAfter) >> 1;

    Codes currentAbove = window.above[3];
    Codes currentBelow = window.below[3];
    Codes previousDifference = (
        abs(sampleCodes<Codes, TenBit>(previous, x, aboveY) - currentAbove)
        + abs(sampleCodes<Codes, TenBit>(previous, x, belowY) - currentBelow)
    ) >> 1;
    Codes nextDifference = (
        abs(sampleCodes<Codes, TenBit>(next, x, aboveY) - currentAbove)
        + abs(sampleCodes<Codes, TenBit>(next, x, belowY) - currentBelow)
    ) >> 1;
    Codes bound = max(centerDifference, max(previousDifference, nextDifference));

    if (y != 1 && y + 2 != height) {
        int farAboveY = y + 2 * (aboveY - y);
        int farBelowY = y + 2 * (belowY - y);
        Codes farAbove = (
            sampleCodes<Codes, TenBit>(before, x, farAboveY)
            + sampleCodes<Codes, TenBit>(after, x, farAboveY)
        ) >> 1;
        Codes farBelow = (
            sampleCodes<Codes, TenBit>(before, x, farBelowY)
            + sampleCodes<Codes, TenBit>(after, x, farBelowY)
        ) >> 1;
        Codes upper = max(
            center - currentBelow,
            max(
                center - currentAbove,
                min(farAbove - currentAbove, farBelow - currentBelow)
            )
        );
        Codes lower = min(
            center - currentBelow,
            min(
                center - currentAbove,
                max(farAbove - currentAbove, farBelow - currentBelow)
            )
        );
        bound = max(bound, max(lower, -upper));
    }
    return clamp(prediction, center - bound, center + bound);
}

// One thread owns one row pair: the line copied straight from the current
// picture and the line synthesized between its neighbours. Dispatching over the
// full output instead made half the threads do a texture copy and the other half
// the whole filter, for twice the threads and no extra work done.
template <typename Codes, bool TenBit>
inline void runYADIF(
    texture2d<float, access::read> previous,
    texture2d<float, access::read> current,
    texture2d<float, access::read> next,
    texture2d<float, access::write> output,
    constant YADIFKernelUniforms &uniforms,
    uint2 position
) {
    int width = int(output.get_width());
    int height = int(output.get_height());
    int x = int(position.x);
    if (x >= width) {
        return;
    }

    int firstParity = uniforms.topFieldFirst != 0 ? 0 : 1;
    int copiedParity = uniforms.outputIndex == 0 ? firstParity : 1 - firstParity;
    int rowPair = int(position.y) * 2;
    int copiedY = rowPair + copiedParity;
    int synthesizedY = rowPair + 1 - copiedParity;

    if (copiedY < height) {
        output.write(
            PlaneCodec<Codes>::encode(
                sampleCodes<Codes, TenBit>(current, x, copiedY),
                TenBit
            ),
            uint2(uint(x), uint(copiedY))
        );
    }
    if (synthesizedY >= height) {
        return;
    }

    int aboveY = synthesizedY == 0 ? 1 : synthesizedY - 1;
    int belowY = synthesizedY + 1 == height ? height - 2 : synthesizedY + 1;
    FieldWindow<Codes> window;
    window.above[0] = sampleCodes<Codes, TenBit>(current, x - 3, aboveY);
    window.above[1] = sampleCodes<Codes, TenBit>(current, x - 2, aboveY);
    window.above[2] = sampleCodes<Codes, TenBit>(current, x - 1, aboveY);
    window.above[3] = sampleCodes<Codes, TenBit>(current, x, aboveY);
    window.above[4] = sampleCodes<Codes, TenBit>(current, x + 1, aboveY);
    window.above[5] = sampleCodes<Codes, TenBit>(current, x + 2, aboveY);
    window.above[6] = sampleCodes<Codes, TenBit>(current, x + 3, aboveY);
    window.below[0] = sampleCodes<Codes, TenBit>(current, x - 3, belowY);
    window.below[1] = sampleCodes<Codes, TenBit>(current, x - 2, belowY);
    window.below[2] = sampleCodes<Codes, TenBit>(current, x - 1, belowY);
    window.below[3] = sampleCodes<Codes, TenBit>(current, x, belowY);
    window.below[4] = sampleCodes<Codes, TenBit>(current, x + 1, belowY);
    window.below[5] = sampleCodes<Codes, TenBit>(current, x + 2, belowY);
    window.below[6] = sampleCodes<Codes, TenBit>(current, x + 3, belowY);

    Codes code = synthesize<Codes, TenBit>(
        previous,
        current,
        next,
        window,
        x,
        synthesizedY,
        aboveY,
        belowY,
        width,
        height,
        uniforms
    );
    output.write(
        PlaneCodec<Codes>::encode(code, TenBit),
        uint2(uint(x), uint(synthesizedY))
    );
}

kernel void yadifPlane8(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF<int, false>(previous, current, next, output, uniforms, position);
}

kernel void yadifPlane16(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF<int, true>(previous, current, next, output, uniforms, position);
}

kernel void yadifChroma8(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF<int2, false>(previous, current, next, output, uniforms, position);
}

kernel void yadifChroma16(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF<int2, true>(previous, current, next, output, uniforms, position);
}
