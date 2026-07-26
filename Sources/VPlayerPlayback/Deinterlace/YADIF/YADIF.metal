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

// YADIF receives at most 10-bit code values. Its largest intermediate here is
// a sum of three absolute differences (3 * 1023), so signed 16-bit lanes are
// exact while using half the register and threadgroup storage of int lanes.
template <> struct PlaneCodec<short> {
    static inline short decode(uint4 texel, bool tenBit) {
        return tenBit ? short(texel.x >> 6) : short(texel.x);
    }

    static inline uint4 encode(short codes, bool tenBit) {
        uint value = tenBit ? (uint(codes) << 6) : uint(codes);
        return uint4(value, 0, 0, 0);
    }
};

template <> struct PlaneCodec<short2> {
    static inline short2 decode(uint4 texel, bool tenBit) {
        return tenBit ? short2(texel.xy >> 6) : short2(texel.xy);
    }

    static inline uint4 encode(short2 codes, bool tenBit) {
        uint2 value = tenBit ? (uint2(codes) << 6) : uint2(codes);
        return uint4(value.x, value.y, 0, 0);
    }
};

template <typename Codes, bool TenBit>
inline Codes readCodes(
    texture2d<uint, access::read> image,
    int x,
    int y
) {
    return PlaneCodec<Codes>::decode(
        image.read(uint2(uint(x), uint(y))),
        TenBit
    );
}

// Only the horizontal threadgroup halo can leave the image. Every vertical
// coordinate and every temporal sample is derived from an in-range output row,
// so keeping their old per-read size queries and clamps wastes ALU work in the
// hottest part of the filter.
template <typename Codes, bool TenBit>
inline Codes readCodesClampedX(
    texture2d<uint, access::read> image,
    int x,
    int y,
    int width
) {
    return readCodes<Codes, TenBit>(image, clamp(x, 0, width - 1), y);
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
    Codes maskedFarScore = select(Codes(0x7fff), farScore, nearScore < score);

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
    texture2d<uint, access::read> previous,
    texture2d<uint, access::read> current,
    texture2d<uint, access::read> next,
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

    texture2d<uint, access::read> before = uniforms.outputIndex == 0
        ? previous
        : current;
    texture2d<uint, access::read> after = uniforms.outputIndex == 0
        ? current
        : next;

    Codes temporalBefore = readCodes<Codes, TenBit>(before, x, y);
    Codes temporalAfter = readCodes<Codes, TenBit>(after, x, y);
    Codes center = (temporalBefore + temporalAfter) >> 1;
    Codes centerDifference = abs(temporalBefore - temporalAfter) >> 1;

    Codes currentAbove = window.above[3];
    Codes currentBelow = window.below[3];
    Codes previousDifference = (
        abs(readCodes<Codes, TenBit>(previous, x, aboveY) - currentAbove)
        + abs(readCodes<Codes, TenBit>(previous, x, belowY) - currentBelow)
    ) >> 1;
    Codes nextDifference = (
        abs(readCodes<Codes, TenBit>(next, x, aboveY) - currentAbove)
        + abs(readCodes<Codes, TenBit>(next, x, belowY) - currentBelow)
    ) >> 1;
    Codes bound = max(centerDifference, max(previousDifference, nextDifference));

    if (y != 1 && y + 2 != height) {
        int farAboveY = y + 2 * (aboveY - y);
        int farBelowY = y + 2 * (belowY - y);
        Codes farAbove = (
            readCodes<Codes, TenBit>(before, x, farAboveY)
            + readCodes<Codes, TenBit>(after, x, farAboveY)
        ) >> 1;
        Codes farBelow = (
            readCodes<Codes, TenBit>(before, x, farBelowY)
            + readCodes<Codes, TenBit>(after, x, farBelowY)
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
        Codes negatedUpper = -upper;
        bound = max(bound, max(lower, negatedUpper));
    }
    Codes minimum = center - bound;
    Codes maximum = center + bound;
    return clamp(prediction, minimum, maximum);
}

// One thread owns one row pair: the line copied straight from the current
// picture and the line synthesized between its neighbours. Dispatching over the
// full output instead made half the threads do a texture copy and the other half
// the whole filter, for twice the threads and no extra work done.
template <typename Codes, bool TenBit>
inline void runYADIF(
    texture2d<uint, access::read> previous,
    texture2d<uint, access::read> current,
    texture2d<uint, access::read> next,
    texture2d<uint, access::write> output,
    threadgroup Codes *spatialRows,
    constant YADIFKernelUniforms &uniforms,
    uint2 position,
    uint2 localPosition,
    uint2 threadsPerThreadgroup
) {
    int width = int(output.get_width());
    int height = int(output.get_height());
    int x = int(position.x);
    int firstParity = uniforms.topFieldFirst != 0 ? 0 : 1;
    int copiedParity = uniforms.outputIndex == 0 ? firstParity : 1 - firstParity;
    int rowPairCount = (height + 1) / 2;

    int safeRowPair = min(int(position.y), rowPairCount - 1) * 2;
    int safeSynthesizedY = safeRowPair + 1 - copiedParity;
    int safeAboveY = safeSynthesizedY == 0 ? 1 : safeSynthesizedY - 1;
    int safeBelowY = safeSynthesizedY + 1 == height
        ? height - 2
        : safeSynthesizedY + 1;
    int groupOriginX = x - int(localPosition.x);
    uint rowStride = threadsPerThreadgroup.x + 6;
    uint aboveBase = localPosition.y * rowStride * 2;
    uint belowBase = aboveBase + rowStride;
    uint sharedX = localPosition.x + 3;
    spatialRows[aboveBase + sharedX] = readCodesClampedX<Codes, TenBit>(
        current, x, safeAboveY, width
    );
    spatialRows[belowBase + sharedX] = readCodesClampedX<Codes, TenBit>(
        current, x, safeBelowY, width
    );
    if (localPosition.x < 3) {
        int leftX = groupOriginX + int(localPosition.x) - 3;
        int rightX = groupOriginX
            + int(threadsPerThreadgroup.x)
            + int(localPosition.x);
        spatialRows[aboveBase + localPosition.x] = readCodesClampedX<Codes, TenBit>(
            current, leftX, safeAboveY, width
        );
        spatialRows[belowBase + localPosition.x] = readCodesClampedX<Codes, TenBit>(
            current, leftX, safeBelowY, width
        );
        spatialRows[aboveBase + threadsPerThreadgroup.x + 3 + localPosition.x]
            = readCodesClampedX<Codes, TenBit>(current, rightX, safeAboveY, width);
        spatialRows[belowBase + threadsPerThreadgroup.x + 3 + localPosition.x]
            = readCodesClampedX<Codes, TenBit>(current, rightX, safeBelowY, width);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (x >= width || int(position.y) >= rowPairCount) {
        return;
    }
    int rowPair = int(position.y) * 2;
    int copiedY = rowPair + copiedParity;
    int synthesizedY = rowPair + 1 - copiedParity;

    if (copiedY < height) {
        output.write(
            PlaneCodec<Codes>::encode(
                readCodes<Codes, TenBit>(current, x, copiedY),
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
    window.above[0] = spatialRows[aboveBase + localPosition.x];
    window.above[1] = spatialRows[aboveBase + localPosition.x + 1];
    window.above[2] = spatialRows[aboveBase + localPosition.x + 2];
    window.above[3] = spatialRows[aboveBase + localPosition.x + 3];
    window.above[4] = spatialRows[aboveBase + localPosition.x + 4];
    window.above[5] = spatialRows[aboveBase + localPosition.x + 5];
    window.above[6] = spatialRows[aboveBase + localPosition.x + 6];
    window.below[0] = spatialRows[belowBase + localPosition.x];
    window.below[1] = spatialRows[belowBase + localPosition.x + 1];
    window.below[2] = spatialRows[belowBase + localPosition.x + 2];
    window.below[3] = spatialRows[belowBase + localPosition.x + 3];
    window.below[4] = spatialRows[belowBase + localPosition.x + 4];
    window.below[5] = spatialRows[belowBase + localPosition.x + 5];
    window.below[6] = spatialRows[belowBase + localPosition.x + 6];

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
    texture2d<uint, access::read> previous [[texture(0)]],
    texture2d<uint, access::read> current [[texture(1)]],
    texture2d<uint, access::read> next [[texture(2)]],
    texture2d<uint, access::write> output [[texture(3)]],
    threadgroup short *spatialRows [[threadgroup(0)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    uint2 localPosition [[thread_position_in_threadgroup]],
    uint2 threadsPerThreadgroup [[threads_per_threadgroup]]
) {
    runYADIF<short, false>(
        previous, current, next, output, spatialRows, uniforms,
        position, localPosition, threadsPerThreadgroup
    );
}

kernel void yadifPlane16(
    texture2d<uint, access::read> previous [[texture(0)]],
    texture2d<uint, access::read> current [[texture(1)]],
    texture2d<uint, access::read> next [[texture(2)]],
    texture2d<uint, access::write> output [[texture(3)]],
    threadgroup short *spatialRows [[threadgroup(0)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    uint2 localPosition [[thread_position_in_threadgroup]],
    uint2 threadsPerThreadgroup [[threads_per_threadgroup]]
) {
    runYADIF<short, true>(
        previous, current, next, output, spatialRows, uniforms,
        position, localPosition, threadsPerThreadgroup
    );
}

kernel void yadifChroma8(
    texture2d<uint, access::read> previous [[texture(0)]],
    texture2d<uint, access::read> current [[texture(1)]],
    texture2d<uint, access::read> next [[texture(2)]],
    texture2d<uint, access::write> output [[texture(3)]],
    threadgroup short2 *spatialRows [[threadgroup(0)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    uint2 localPosition [[thread_position_in_threadgroup]],
    uint2 threadsPerThreadgroup [[threads_per_threadgroup]]
) {
    runYADIF<short2, false>(
        previous, current, next, output, spatialRows, uniforms,
        position, localPosition, threadsPerThreadgroup
    );
}

kernel void yadifChroma16(
    texture2d<uint, access::read> previous [[texture(0)]],
    texture2d<uint, access::read> current [[texture(1)]],
    texture2d<uint, access::read> next [[texture(2)]],
    texture2d<uint, access::write> output [[texture(3)]],
    threadgroup short2 *spatialRows [[threadgroup(0)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    uint2 localPosition [[thread_position_in_threadgroup]],
    uint2 threadsPerThreadgroup [[threads_per_threadgroup]]
) {
    runYADIF<short2, true>(
        previous, current, next, output, spatialRows, uniforms,
        position, localPosition, threadsPerThreadgroup
    );
}
