// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <metal_stdlib>
using namespace metal;

struct ProbeResult {
    ushort comb;
    ushort motion;
};

kernel void scanProbe(
    texture2d<float, access::read> previousLuma [[texture(0)]],
    texture2d<float, access::read> currentLuma [[texture(1)]],
    device ProbeResult *results [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 64 || gid.y >= 36) {
        return;
    }

    const uint sourceWidth = currentLuma.get_width();
    const uint sourceHeight = currentLuma.get_height();
    const uint x = min(
        uint((float(gid.x) + 0.5f) * float(sourceWidth) / 64.0f),
        sourceWidth - 1
    );
    const uint y = clamp(
        uint((float(gid.y) + 0.5f) * float(sourceHeight) / 36.0f),
        1u,
        sourceHeight - 2
    );
    const float center = currentLuma.read(uint2(x, y)).r;
    const float vertical = 0.5f * (
        currentLuma.read(uint2(x, y - 1)).r
        + currentLuma.read(uint2(x, y + 1)).r
    );
    const float previous = previousLuma.read(uint2(x, y)).r;
    const float comb = clamp(abs(center - vertical), 0.0f, 1.0f);
    const float motion = clamp(abs(center - previous), 0.0f, 1.0f);
    results[gid.y * 64 + gid.x] = {
        ushort(comb * 65535.0f),
        ushort(motion * 65535.0f)
    };
}
