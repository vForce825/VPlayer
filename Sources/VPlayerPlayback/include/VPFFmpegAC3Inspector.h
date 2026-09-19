// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VPFF_AC3_INSPECTOR_ABI_VERSION ((uint32_t)1)
#define VPFF_AC3_SUPPORTED_FSCOD_COUNT ((uint8_t)3)
#define VPFF_AC3_SUPPORTED_BSID_MIN ((uint8_t)0)
#define VPFF_AC3_SUPPORTED_BSID_MAX ((uint8_t)10)
#define VPFF_AC3_SUPPORTED_FRMSIZECOD_COUNT ((uint8_t)38)

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t frame_size;
    int32_t sample_rate;
    int32_t sample_count;
    int32_t channel_count;
    uint8_t fscod;
    uint8_t bsid;
    uint8_t bsmod;
    uint8_t acmod;
    uint8_t lfeon;
    uint8_t frmsizecod;
    uint8_t reserved[2];
} VPFFAC3FrameInfoV1;

/* 输入字节只在本次调用中借用；成功结果严格对应一个完整且CRC有效的经典AC-3 syncframe。 */
int32_t vp_ffmpeg_inspect_ac3_frame_v1(
    const uint8_t *bytes,
    size_t size,
    VPFFAC3FrameInfoV1 *out_info
);

/* 返回真实header parser对fscod/bsid组合采用的采样率；非法组合返回负值。 */
int32_t vp_ffmpeg_ac3_supported_sample_rate_v1(
    uint8_t fscod,
    uint8_t bsid
);

#ifdef __cplusplus
}
#endif

#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
#define VPFF_AC3_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define VPFF_AC3_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, abi_version) == 0,
                       "VPFFAC3FrameInfoV1.abi_version ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, struct_size) == 4,
                       "VPFFAC3FrameInfoV1.struct_size ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, frame_size) == 8,
                       "VPFFAC3FrameInfoV1.frame_size ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, sample_rate) == 12,
                       "VPFFAC3FrameInfoV1.sample_rate ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, sample_count) == 16,
                       "VPFFAC3FrameInfoV1.sample_count ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, channel_count) == 20,
                       "VPFFAC3FrameInfoV1.channel_count ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, fscod) == 24,
                       "VPFFAC3FrameInfoV1.fscod ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, bsid) == 25,
                       "VPFFAC3FrameInfoV1.bsid ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, bsmod) == 26,
                       "VPFFAC3FrameInfoV1.bsmod ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, acmod) == 27,
                       "VPFFAC3FrameInfoV1.acmod ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, lfeon) == 28,
                       "VPFFAC3FrameInfoV1.lfeon ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, frmsizecod) == 29,
                       "VPFFAC3FrameInfoV1.frmsizecod ABI");
VPFF_AC3_STATIC_ASSERT(offsetof(VPFFAC3FrameInfoV1, reserved) == 30,
                       "VPFFAC3FrameInfoV1.reserved ABI");
VPFF_AC3_STATIC_ASSERT(sizeof(VPFFAC3FrameInfoV1) == 32,
                       "VPFFAC3FrameInfoV1 size ABI");
#undef VPFF_AC3_STATIC_ASSERT
#endif
