// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VPFF_VIDEO_DECODER_ABI_VERSION ((uint32_t)1)
#define VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT INT32_C(1)

typedef struct VPFFVideoDecoder VPFFVideoDecoder;

typedef enum {
    VPFF_VIDEO_RANGE_UNKNOWN = 0,
    VPFF_VIDEO_RANGE_VIDEO = 1,
    VPFF_VIDEO_RANGE_FULL = 2,
} VPFFVideoRange;

/* Planar 8-bit 4:2:0, which is what the H.264 decoder produces. The planes and
   their strides are borrowed only for the duration of the synchronous callback;
   the receiver must copy anything it keeps. */
typedef struct {
    const uint8_t *luma;
    const uint8_t *chroma_b;
    const uint8_t *chroma_r;
    int32_t luma_stride, chroma_b_stride, chroma_r_stride;
    int32_t width, height;
    /* Opaque signed token supplied to push; this is not a media timestamp. */
    int64_t pts;

    uint32_t abi_version;
    uint32_t struct_size;

    uint8_t is_interlaced;
    uint8_t top_field_first;
    uint8_t reserved[2];
    VPFFVideoRange range;
    /* Raw ITU-T H.273 code points, translated by the caller. */
    int32_t color_primaries, color_transfer, color_matrix;
} VPFFVideoFrame;

typedef void (*VPFFVideoFrameCallback)(void *context, const VPFFVideoFrame *frame);

/* Extradata is the avcC record, borrowed only for create, NULL iff size is zero.
   `thread_count` of zero lets the decoder choose. */
int32_t vp_ffmpeg_video_decoder_create(
    const uint8_t *extradata,
    size_t extradata_size,
    int32_t thread_count,
    VPFFVideoFrameCallback callback,
    void *context,
    VPFFVideoDecoder **out_decoder
);

/* Access-unit bytes are borrowed only for this call and are NULL iff size is
   zero. Frames complete through the callback before this returns. Both output
   pointers are required and report the token for an unsupported output, if the
   decoder produced one with a positive PTS. */
int32_t vp_ffmpeg_video_decoder_push(
    VPFFVideoDecoder *decoder,
    const uint8_t *bytes,
    size_t size,
    int64_t pts,
    int64_t *out_failure_token,
    uint8_t *out_has_failure_token
);

/* Writes one decoded picture into a bi-planar destination: the luma plane row
   by row, and the two chroma planes interleaved into one. Separate from the
   decoder so the interleave can use the vector store built for exactly this,
   rather than a per-byte loop in a language whose debug builds do not optimise
   one. Buffers must not overlap. */
void vp_ffmpeg_video_write_biplanar(
    const uint8_t *luma, int32_t luma_stride,
    const uint8_t *chroma_b, int32_t chroma_b_stride,
    const uint8_t *chroma_r, int32_t chroma_r_stride,
    uint8_t *destination_luma, size_t destination_luma_stride,
    uint8_t *destination_chroma, size_t destination_chroma_stride,
    int32_t width, int32_t height
);

void vp_ffmpeg_video_decoder_flush(VPFFVideoDecoder *decoder);
void vp_ffmpeg_video_decoder_destroy(VPFFVideoDecoder *decoder);

#ifdef __cplusplus
}
#endif

#if UINTPTR_MAX == UINT64_MAX
#if defined(__cplusplus)
#define VPFF_VIDEO_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define VPFF_VIDEO_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, luma) == 0, "VPFFVideoFrame.luma ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, chroma_b) == 8, "VPFFVideoFrame.chroma_b ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, chroma_r) == 16, "VPFFVideoFrame.chroma_r ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, luma_stride) == 24, "VPFFVideoFrame.luma_stride ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, width) == 36, "VPFFVideoFrame.width ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, height) == 40, "VPFFVideoFrame.height ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, pts) == 48, "VPFFVideoFrame.pts ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, abi_version) == 56, "VPFFVideoFrame.abi_version ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, struct_size) == 60, "VPFFVideoFrame.struct_size ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, is_interlaced) == 64, "VPFFVideoFrame.is_interlaced ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, range) == 68, "VPFFVideoFrame.range ABI");
VPFF_VIDEO_STATIC_ASSERT(offsetof(VPFFVideoFrame, color_matrix) == 80, "VPFFVideoFrame.color_matrix ABI");
VPFF_VIDEO_STATIC_ASSERT(sizeof(VPFFVideoFrame) == 88, "VPFFVideoFrame size ABI");
#undef VPFF_VIDEO_STATIC_ASSERT
#endif
