// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <metal_stdlib>
using namespace metal;

struct YADIFKernelUniforms {
    uint outputIndex;
    uint topFieldFirst;
    uint spatialOnly;
    uint componentCount;
};

inline int sampleCode(
    texture2d<float, access::read> image,
    int x,
    int y,
    uint component,
    bool tenBit
) {
    int boundedX = clamp(x, 0, int(image.get_width()) - 1);
    int boundedY = clamp(y, 0, int(image.get_height()) - 1);
    float value = clamp(image.read(uint2(boundedX, boundedY))[component], 0.0f, 1.0f);
    if (tenBit) {
        return int(round(value * 65535.0f)) >> 6;
    }
    return int(round(value * 255.0f));
}

struct SpatialSearchState {
    int score;
    int prediction;
};

inline int directionalScore(
    texture2d<float, access::read> current,
    int x,
    int aboveY,
    int belowY,
    int direction,
    uint component,
    bool tenBit
) {
    int score = 0;
    for (int offset = -1; offset <= 1; ++offset) {
        score += abs(
            sampleCode(
                current,
                x + offset + direction,
                aboveY,
                component,
                tenBit
            )
            - sampleCode(
                current,
                x + offset - direction,
                belowY,
                component,
                tenBit
            )
        );
    }
    return score;
}

inline SpatialSearchState refineDirectionPair(
    texture2d<float, access::read> current,
    int x,
    int aboveY,
    int belowY,
    int sign,
    uint component,
    bool tenBit,
    SpatialSearchState state
) {
    int nearDirection = sign;
    int nearScore = directionalScore(
        current, x, aboveY, belowY, nearDirection, component, tenBit
    );
    if (nearScore >= state.score) {
        return state;
    }
    state.score = nearScore;
    state.prediction = (
        sampleCode(current, x + nearDirection, aboveY, component, tenBit)
        + sampleCode(current, x - nearDirection, belowY, component, tenBit)
    ) >> 1;

    int farDirection = sign * 2;
    int farScore = directionalScore(
        current, x, aboveY, belowY, farDirection, component, tenBit
    );
    if (farScore < state.score) {
        state.score = farScore;
        state.prediction = (
            sampleCode(current, x + farDirection, aboveY, component, tenBit)
            + sampleCode(current, x - farDirection, belowY, component, tenBit)
        ) >> 1;
    }
    return state;
}

inline int spatialPrediction(
    texture2d<float, access::read> current,
    int x,
    int aboveY,
    int belowY,
    uint component,
    bool tenBit
) {
    int prediction = (
        sampleCode(current, x, aboveY, component, tenBit)
        + sampleCode(current, x, belowY, component, tenBit)
    ) >> 1;
    int width = int(current.get_width());
    if (x < 3 || x + 3 >= width) {
        return prediction;
    }

    int defaultScore = -1;
    for (int offset = -1; offset <= 1; ++offset) {
        defaultScore += abs(
            sampleCode(current, x + offset, aboveY, component, tenBit)
            - sampleCode(current, x + offset, belowY, component, tenBit)
        );
    }
    SpatialSearchState state = {defaultScore, prediction};
    state = refineDirectionPair(
        current, x, aboveY, belowY, -1, component, tenBit, state
    );
    state = refineDirectionPair(
        current, x, aboveY, belowY, 1, component, tenBit, state
    );
    return state.prediction;
}

inline int synthesize(
    texture2d<float, access::read> previous,
    texture2d<float, access::read> current,
    texture2d<float, access::read> next,
    int x,
    int y,
    uint component,
    bool tenBit,
    constant YADIFKernelUniforms &uniforms
) {
    int height = int(current.get_height());
    int aboveY = y == 0 ? 1 : y - 1;
    int belowY = y + 1 == height ? height - 2 : y + 1;
    int prediction = spatialPrediction(
        current,
        x,
        aboveY,
        belowY,
        component,
        tenBit
    );
    if (uniforms.spatialOnly != 0) {
        return prediction;
    }

    bool firstOutput = uniforms.outputIndex == 0;
    int temporalBefore = sampleCode(
        firstOutput ? previous : current,
        x,
        y,
        component,
        tenBit
    );
    int temporalAfter = sampleCode(
        firstOutput ? current : next,
        x,
        y,
        component,
        tenBit
    );
    int center = (temporalBefore + temporalAfter) >> 1;
    int centerDifference = abs(temporalBefore - temporalAfter) >> 1;
    int previousDifference = (
        abs(
            sampleCode(previous, x, aboveY, component, tenBit)
            - sampleCode(current, x, aboveY, component, tenBit)
        )
        + abs(
            sampleCode(previous, x, belowY, component, tenBit)
            - sampleCode(current, x, belowY, component, tenBit)
        )
    ) >> 1;
    int nextDifference = (
        abs(
            sampleCode(next, x, aboveY, component, tenBit)
            - sampleCode(current, x, aboveY, component, tenBit)
        )
        + abs(
            sampleCode(next, x, belowY, component, tenBit)
            - sampleCode(current, x, belowY, component, tenBit)
        )
    ) >> 1;
    int bound = max(centerDifference, max(previousDifference, nextDifference));

    if (y != 1 && y + 2 != height) {
        int farAboveY = y + 2 * (aboveY - y);
        int farBelowY = y + 2 * (belowY - y);
        int farAbove = (
            sampleCode(
                firstOutput ? previous : current,
                x,
                farAboveY,
                component,
                tenBit
            )
            + sampleCode(
                firstOutput ? current : next,
                x,
                farAboveY,
                component,
                tenBit
            )
        ) >> 1;
        int farBelow = (
            sampleCode(
                firstOutput ? previous : current,
                x,
                farBelowY,
                component,
                tenBit
            )
            + sampleCode(
                firstOutput ? current : next,
                x,
                farBelowY,
                component,
                tenBit
            )
        ) >> 1;
        int currentAbove = sampleCode(current, x, aboveY, component, tenBit);
        int currentBelow = sampleCode(current, x, belowY, component, tenBit);
        int upper = max(
            center - currentBelow,
            max(
                center - currentAbove,
                min(farAbove - currentAbove, farBelow - currentBelow)
            )
        );
        int lower = min(
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

inline void runYADIF(
    texture2d<float, access::read> previous,
    texture2d<float, access::read> current,
    texture2d<float, access::read> next,
    texture2d<float, access::write> output,
    constant YADIFKernelUniforms &uniforms,
    uint2 position,
    bool tenBit
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    uint firstParity = uniforms.topFieldFirst != 0 ? 0 : 1;
    uint copiedParity = uniforms.outputIndex == 0 ? firstParity : 1 - firstParity;
    bool copyCurrent = (position.y & 1) == copiedParity;
    float4 result = float4(0.0f, 0.0f, 0.0f, 1.0f);
    for (uint component = 0; component < uniforms.componentCount; ++component) {
        int code = copyCurrent
            ? sampleCode(current, int(position.x), int(position.y), component, tenBit)
            : synthesize(
                previous,
                current,
                next,
                int(position.x),
                int(position.y),
                component,
                tenBit,
                uniforms
            );
        result[component] = tenBit
            ? float(code << 6) / 65535.0f
            : float(code) / 255.0f;
    }
    output.write(result, position);
}

kernel void yadifPlane8(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF(previous, current, next, output, uniforms, position, false);
}

kernel void yadifPlane16(
    texture2d<float, access::read> previous [[texture(0)]],
    texture2d<float, access::read> current [[texture(1)]],
    texture2d<float, access::read> next [[texture(2)]],
    texture2d<float, access::write> output [[texture(3)]],
    constant YADIFKernelUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    runYADIF(previous, current, next, output, uniforms, position, true);
}
