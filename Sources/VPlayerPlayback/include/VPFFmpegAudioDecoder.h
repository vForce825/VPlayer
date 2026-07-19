// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <VPlayerPlayback/VPFFmpegDemuxer.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VPFF_AUDIO_DECODER_ABI_VERSION ((uint32_t)1)

typedef struct VPFFAudioDecoder VPFFAudioDecoder;

typedef struct {
    /* Borrowed only until the synchronous callback returns. */
    const float *interleaved;
    size_t frame_count;
    int32_t sample_rate, channels;
    /* Opaque signed token supplied to push; this is not a media timestamp. */
    int64_t pts;

    uint32_t abi_version;
    uint32_t struct_size;
    VPFFChannelOrder channel_order;
    uint8_t has_channel_layout_mask;
    uint8_t reserved[3];
    uint64_t channel_layout_mask;
} VPFFPCMFrame;

/* The frame and its interleaved pointer are borrowed only for this synchronous call. */
typedef void (*VPFFPCMCallback)(void *context, const VPFFPCMFrame *frame);

/* Extradata is borrowed only for create and is NULL iff extradata_size is zero. */
int32_t vp_ffmpeg_audio_decoder_create(
    VPFFCodec codec,
    const uint8_t *extradata,
    size_t extradata_size,
    VPFFPCMCallback callback,
    void *context,
    VPFFAudioDecoder **out_decoder
);

/* Packet bytes are borrowed only for this call and are NULL iff size is zero. */
int32_t vp_ffmpeg_audio_decoder_push(
    VPFFAudioDecoder *decoder,
    const uint8_t *bytes,
    size_t size,
    int64_t pts
);

void vp_ffmpeg_audio_decoder_flush(VPFFAudioDecoder *decoder);
void vp_ffmpeg_audio_decoder_destroy(VPFFAudioDecoder *decoder);

#ifdef __cplusplus
}
#endif

#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
static_assert(offsetof(VPFFPCMFrame, interleaved) == 0, "VPFFPCMFrame.interleaved ABI");
static_assert(offsetof(VPFFPCMFrame, frame_count) == 8, "VPFFPCMFrame.frame_count ABI");
static_assert(offsetof(VPFFPCMFrame, sample_rate) == 16, "VPFFPCMFrame.sample_rate ABI");
static_assert(offsetof(VPFFPCMFrame, channels) == 20, "VPFFPCMFrame.channels ABI");
static_assert(offsetof(VPFFPCMFrame, pts) == 24, "VPFFPCMFrame.pts ABI");
static_assert(offsetof(VPFFPCMFrame, abi_version) == 32, "VPFFPCMFrame.abi_version ABI");
static_assert(offsetof(VPFFPCMFrame, struct_size) == 36, "VPFFPCMFrame.struct_size ABI");
static_assert(offsetof(VPFFPCMFrame, channel_order) == 40, "VPFFPCMFrame.channel_order ABI");
static_assert(offsetof(VPFFPCMFrame, has_channel_layout_mask) == 44, "VPFFPCMFrame.has_mask ABI");
static_assert(offsetof(VPFFPCMFrame, channel_layout_mask) == 48, "VPFFPCMFrame.mask ABI");
static_assert(sizeof(VPFFPCMFrame) == 56, "VPFFPCMFrame size ABI");
#else
_Static_assert(offsetof(VPFFPCMFrame, interleaved) == 0, "VPFFPCMFrame.interleaved ABI");
_Static_assert(offsetof(VPFFPCMFrame, frame_count) == 8, "VPFFPCMFrame.frame_count ABI");
_Static_assert(offsetof(VPFFPCMFrame, sample_rate) == 16, "VPFFPCMFrame.sample_rate ABI");
_Static_assert(offsetof(VPFFPCMFrame, channels) == 20, "VPFFPCMFrame.channels ABI");
_Static_assert(offsetof(VPFFPCMFrame, pts) == 24, "VPFFPCMFrame.pts ABI");
_Static_assert(offsetof(VPFFPCMFrame, abi_version) == 32, "VPFFPCMFrame.abi_version ABI");
_Static_assert(offsetof(VPFFPCMFrame, struct_size) == 36, "VPFFPCMFrame.struct_size ABI");
_Static_assert(offsetof(VPFFPCMFrame, channel_order) == 40, "VPFFPCMFrame.channel_order ABI");
_Static_assert(offsetof(VPFFPCMFrame, has_channel_layout_mask) == 44, "VPFFPCMFrame.has_mask ABI");
_Static_assert(offsetof(VPFFPCMFrame, channel_layout_mask) == 48, "VPFFPCMFrame.mask ABI");
_Static_assert(sizeof(VPFFPCMFrame) == 56, "VPFFPCMFrame size ABI");
#endif
#endif
