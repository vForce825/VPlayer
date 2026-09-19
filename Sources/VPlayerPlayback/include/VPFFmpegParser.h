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

#define VPFF_PARSER_ABI_VERSION ((uint32_t)1)
#define VPFF_PARSER_ABI_VERSION_V2 ((uint32_t)2)

typedef struct VPFFParser VPFFParser;

typedef enum {
    VPFF_PICTURE_STRUCTURE_UNKNOWN = 0,
    VPFF_PICTURE_STRUCTURE_FRAME = 1,
    VPFF_PICTURE_STRUCTURE_TOP_FIELD = 2,
    VPFF_PICTURE_STRUCTURE_BOTTOM_FIELD = 3
} VPFFPictureStructure;

typedef struct {
    /* Borrowed only until the synchronous callback returns. NULL iff size is zero. */
    const uint8_t *bytes;
    size_t size;
    int64_t pts;
    int64_t dts;
    int64_t duration;
    int32_t field_order;
    int32_t picture_structure;
    int8_t key_frame;
    int8_t repeat_pict;
    int8_t top_field_first;
    int8_t interlaced;
    int32_t sample_rate;
    int32_t channels;
    int32_t frame_samples;

    /* ABI v1 extension: independently scaled duration and copied channel layout. */
    int64_t duration_value;
    int32_t duration_timescale;
    VPFFChannelOrder channel_order;
    uint8_t has_channel_layout_mask;
    uint64_t channel_layout_mask;
} VPFFParsedFrame;

/* The frame and every borrowed pointer are valid only during this synchronous call. */
typedef void (*VPFFParserCallback)(void *context, const VPFFParsedFrame *frame);

typedef enum {
    VPFF_PARSER_ALLOCATION_EXTRADATA = 1,
    VPFF_PARSER_ALLOCATION_PUSH_INPUT = 2,
} VPFFParserAllocationKind;

/*
 * HLS 可选的原生副本接管钩子。reserve 必须在对应 av_mallocz 前返回非 NULL
 * token；release 只在该 backing 已由原生层实际释放后调用一次。token 的所有权
 * 完全属于调用方，C 层不检查或释放它。
 */
typedef void *(*VPFFParserAllocationReserveCallback)(
    void *context,
    VPFFParserAllocationKind kind,
    size_t bytes
);
typedef void (*VPFFParserAllocationReleaseCallback)(void *context, void *token);

typedef struct {
    VPFFParserAllocationReserveCallback reserve;
    VPFFParserAllocationReleaseCallback release;
    void *context;
} VPFFParserAllocationCallbacks;

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    VPFFCodec codec;
    int32_t time_base_num;
    int32_t time_base_den;
    int32_t sample_rate;
    int32_t channel_count;
    VPFFChannelOrder channel_order;
    uint8_t has_channel_layout_mask;
    uint64_t channel_layout_mask;
    /* Borrowed only for create. NULL iff size is zero. */
    const uint8_t *extradata;
    size_t extradata_size;
} VPFFParserConfigV1;

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    VPFFCodec codec;
    int32_t time_base_num;
    int32_t time_base_den;
    int32_t sample_rate;
    int32_t channel_count;
    VPFFChannelOrder channel_order;
    uint8_t has_channel_layout_mask;
    uint64_t channel_layout_mask;
    const uint8_t *extradata;
    size_t extradata_size;
    VPFFParserAllocationCallbacks allocation_callbacks;
} VPFFParserConfigV2;

/*
 * Compatibility entry point. Because the original ABI has no time base or
 * channel layout, it is restricted to H.264/HEVC with a 1/90000 time base.
 * The extradata pointer is borrowed only for create and is NULL iff size is zero.
 */
int32_t vp_ffmpeg_parser_create(
    VPFFCodec codec,
    const uint8_t *extradata,
    size_t extradata_size,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
);

/* The config and its extradata pointer are borrowed only for this call. */
int32_t vp_ffmpeg_parser_create_v1(
    const VPFFParserConfigV1 *config,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
);

/* v2 仅增加可选的原生 allocation 接管回调；未提供回调时保持 v1 语义。 */
int32_t vp_ffmpeg_parser_create_v2(
    const VPFFParserConfigV2 *config,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
);

/* Input bytes are borrowed only for this call and are NULL iff size is zero. */
int32_t vp_ffmpeg_parser_push(
    VPFFParser *parser,
    const uint8_t *bytes,
    size_t size,
    int64_t pts,
    int64_t dts,
    int64_t duration
);

int32_t vp_ffmpeg_parser_drain(VPFFParser *parser);
void vp_ffmpeg_parser_destroy(VPFFParser *parser);

/* 供 Swift 定向测试核对 native av_mallocz 预留的实际输入尾 padding。 */
size_t vp_ffmpeg_parser_input_padding_bytes(void);

#if DEBUG
/* 仅供测试校验 AVFieldOrder 的显示场序映射。 */
int8_t vp_ffmpeg_parser_debug_top_field_first(
    int32_t field_order,
    int32_t picture_structure
);
#endif

#ifdef __cplusplus
}
#endif
