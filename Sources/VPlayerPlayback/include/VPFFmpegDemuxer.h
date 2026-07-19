// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VPDemuxer VPDemuxer;

typedef enum {
    VPFF_CODEC_UNSUPPORTED = 0,
    VPFF_CODEC_H264 = 1,
    VPFF_CODEC_HEVC = 2,
    VPFF_CODEC_AAC = 3,
    VPFF_CODEC_AC3 = 4,
    VPFF_CODEC_EAC3 = 5,
    VPFF_CODEC_MP2 = 6
} VPFFCodec;

typedef enum {
    VPFF_CHANNEL_ORDER_UNSPECIFIED = 0,
    VPFF_CHANNEL_ORDER_NATIVE = 1,
    VPFF_CHANNEL_ORDER_CUSTOM = 2,
    VPFF_CHANNEL_ORDER_AMBISONIC = 3
} VPFFChannelOrder;

typedef enum {
    VPFF_EVENT_INVALID = 0,
    VPFF_EVENT_TRACKS = 1,
    VPFF_EVENT_PACKET = 2,
    VPFF_EVENT_DISCONTINUITY = 3,
    VPFF_EVENT_END = 4,
    VPFF_EVENT_CANCELLED = 5,
    VPFF_EVENT_ERROR = 6
} VPFFDemuxEventKind;

typedef enum {
    VPFF_DEMUX_ERROR_NONE = 0,
    VPFF_DEMUX_ERROR_OPEN = 1,
    VPFF_DEMUX_ERROR_READ = 2,
    VPFF_DEMUX_ERROR_TIMEOUT = 3,
    VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO = 4,
    VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO = 5
} VPFFDemuxErrorKind;

typedef enum {
    VPFF_DEMUX_STAGE_NONE = 0,
    VPFF_DEMUX_STAGE_VALIDATION = 1,
    VPFF_DEMUX_STAGE_OPEN = 2,
    VPFF_DEMUX_STAGE_STREAM_INFO = 3,
    VPFF_DEMUX_STAGE_SELECTION = 4,
    VPFF_DEMUX_STAGE_BSF_INIT = 5,
    VPFF_DEMUX_STAGE_READ = 6,
    VPFF_DEMUX_STAGE_BSF_SEND = 7,
    VPFF_DEMUX_STAGE_BSF_RECEIVE = 8
} VPFFDemuxErrorStage;

typedef struct {
    uint8_t present;
    int32_t stream_index;
    VPFFCodec codec;
    int32_t time_base_num;
    int32_t time_base_den;
    int32_t width;
    int32_t height;
    int32_t video_delay;
    int32_t sample_rate;
    int32_t channel_count;
    VPFFChannelOrder channel_order;
    uint8_t has_channel_layout_mask;
    uint64_t channel_layout_mask;
    /* Borrowed until the synchronous callback returns. NULL iff size is zero. */
    const uint8_t *extradata;
    size_t extradata_size;
} VPFFTrack;

typedef struct {
    int32_t stream_index;
    VPFFCodec codec;
    /* Borrowed until the synchronous callback returns. NULL iff size is zero. */
    const uint8_t *data;
    size_t size;
    int64_t pts;
    int64_t dts;
    int64_t duration;
    int32_t time_base_num;
    int32_t time_base_den;
    uint8_t is_key;
    uint8_t is_corrupt;
} VPFFPacket;

typedef struct {
    VPFFDemuxEventKind kind;
    uint8_t has_program_id;
    int32_t selected_program_id;
    VPFFTrack video;
    VPFFTrack audio;
    VPFFPacket packet;
    VPFFDemuxErrorKind error_kind;
    VPFFDemuxErrorStage error_stage;
    int32_t ffmpeg_error;
} VPFFDemuxEvent;

/* The event and every borrowed pointer are valid only during this synchronous call. */
typedef void (*VPFFDemuxCallback)(void *context, const VPFFDemuxEvent *event);

int32_t vp_ffmpeg_demuxer_create(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallback callback,
    void *context,
    VPDemuxer **out_demuxer
);
int32_t vp_ffmpeg_demuxer_run(VPDemuxer *demuxer);
void vp_ffmpeg_demuxer_cancel(VPDemuxer *demuxer);
void vp_ffmpeg_demuxer_destroy(VPDemuxer *demuxer);

#ifdef __cplusplus
}
#endif
