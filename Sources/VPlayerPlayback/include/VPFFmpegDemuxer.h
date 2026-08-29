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
    VPFF_CODEC_MP2 = 6,
    VPFF_CODEC_MP1 = 7,
    VPFF_CODEC_MP3 = 8
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

typedef enum {
    VPFF_DISCONTINUITY_NONE = 0,
    VPFF_DISCONTINUITY_FORMAT_CHANGE = 1,
    VPFF_DISCONTINUITY_TIMELINE_RESET = 2
} VPFFDemuxDiscontinuityReason;

typedef struct {
    uint8_t present;
    int32_t stream_index;
    VPFFCodec codec;
    int32_t time_base_num;
    int32_t time_base_den;
    int32_t frame_rate_num;
    int32_t frame_rate_den;
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
    VPFFDemuxDiscontinuityReason discontinuity_reason;
} VPFFDemuxEvent;

#if defined(__cplusplus)
#define VPFF_DEMUX_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#define VPFF_DEMUX_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, kind) == 0, "VPFFDemuxEvent.kind ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, has_program_id) == 4,
                         "VPFFDemuxEvent.has_program_id ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, selected_program_id) == 8,
                         "VPFFDemuxEvent.selected_program_id ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, video) == 16, "VPFFDemuxEvent.video ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, audio) == 96, "VPFFDemuxEvent.audio ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, packet) == 176, "VPFFDemuxEvent.packet ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, error_kind) == 240,
                         "VPFFDemuxEvent.error_kind ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, error_stage) == 244,
                         "VPFFDemuxEvent.error_stage ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, ffmpeg_error) == 248,
                         "VPFFDemuxEvent.ffmpeg_error ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEvent, discontinuity_reason) == 252,
                         "VPFFDemuxEvent.discontinuity_reason ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFDemuxEvent) == 256, "VPFFDemuxEvent size ABI");
#undef VPFF_DEMUX_STATIC_ASSERT

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

#if DEBUG
typedef enum {
    VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_EXACT = 1,
    VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_OVERFLOW = 2,
    VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_EXACT = 3,
    VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_OVERFLOW = 4,
    VPFF_BOOTSTRAP_DEBUG_EOF_BEFORE_DIMENSIONS = 5,
    VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_NO_OUTPUT = 6,
    VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_WITH_OUTPUT = 7,
    VPFF_BOOTSTRAP_DEBUG_REPEATED_ZERO_CONSUMED = 8,
    VPFF_BOOTSTRAP_DEBUG_SNAPSHOT_REPLAY = 9
} VPFFBootstrapDebugScenario;

typedef struct {
    size_t peak_packet_count;
    size_t peak_accounted_bytes;
    size_t replayed_packet_count;
    size_t parser_call_count;
    size_t live_resource_count;
    uint8_t retried_same_input;
    int32_t initial_width;
    int32_t initial_height;
    int32_t first_replay_width;
    int32_t first_replay_time_base_num;
    int32_t first_replay_time_base_den;
    int32_t second_replay_sample_rate;
    int32_t second_replay_time_base_num;
    int32_t second_replay_time_base_den;
    int32_t third_replay_width;
    int32_t third_replay_height;
    int32_t third_replay_time_base_num;
    int32_t third_replay_time_base_den;
} VPFFBootstrapDebugResult;

int32_t vp_ffmpeg_demuxer_debug_run_bootstrap(
    VPFFBootstrapDebugScenario scenario,
    VPFFBootstrapDebugResult *out_result
);
#endif

#ifdef __cplusplus
}
#endif
