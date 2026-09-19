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
    VPFF_FIELD_ORDER_UNKNOWN = 0,
    VPFF_FIELD_ORDER_PROGRESSIVE = 1,
    VPFF_FIELD_ORDER_TT = 2,
    VPFF_FIELD_ORDER_BB = 3,
    VPFF_FIELD_ORDER_TB = 4,
    VPFF_FIELD_ORDER_BT = 5
} VPFFFieldOrder;

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

#define VPFF_DEMUX_EVENT_EXTRAS_VERSION_1 1u

typedef uint64_t VPFFTrackExtrasPresence;
#define VPFF_TRACK_EXTRAS_HAS_ROLE (UINT64_C(1) << 0)
#define VPFF_TRACK_EXTRAS_HAS_LANGUAGE (UINT64_C(1) << 1)
#define VPFF_TRACK_EXTRAS_HAS_SERVICE (UINT64_C(1) << 2)
#define VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS (UINT64_C(1) << 3)
#define VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO (UINT64_C(1) << 4)
#define VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE (UINT64_C(1) << 5)
#define VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES (UINT64_C(1) << 6)
#define VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER (UINT64_C(1) << 7)
#define VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX (UINT64_C(1) << 8)
#define VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION (UINT64_C(1) << 9)
#define VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY (UINT64_C(1) << 10)
#define VPFF_TRACK_EXTRAS_HAS_CONTENT_LIGHT_LEVEL (UINT64_C(1) << 11)
#define VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT (UINT64_C(1) << 12)
#define VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT (UINT64_C(1) << 13)

typedef enum {
    VPFF_TRACK_ROLE_UNKNOWN = 0,
    VPFF_TRACK_ROLE_MAIN = 1,
    VPFF_TRACK_ROLE_ALTERNATE = 2,
    VPFF_TRACK_ROLE_COMMENTARY = 3
} VPFFTrackRole;

typedef enum {
    VPFF_TRACK_SERVICE_UNKNOWN = 0,
    VPFF_TRACK_SERVICE_INDEPENDENT_MAIN = 1,
    VPFF_TRACK_SERVICE_ASSOCIATED = 2,
    VPFF_TRACK_SERVICE_DVS = 3,
    VPFF_TRACK_SERVICE_DEPENDENT = 4,
    VPFF_TRACK_SERVICE_JOC = 5
} VPFFTrackService;

typedef uint64_t VPFFTrackDispositionFlags;
#define VPFF_TRACK_DISPOSITION_DEFAULT (UINT64_C(1) << 0)
#define VPFF_TRACK_DISPOSITION_FORCED (UINT64_C(1) << 1)
#define VPFF_TRACK_DISPOSITION_HEARING_IMPAIRED (UINT64_C(1) << 2)
#define VPFF_TRACK_DISPOSITION_VISUAL_IMPAIRED (UINT64_C(1) << 3)
#define VPFF_TRACK_DISPOSITION_COMMENTARY (UINT64_C(1) << 4)
#define VPFF_TRACK_DISPOSITION_DEPENDENT (UINT64_C(1) << 5)

typedef enum {
    VPFF_COLOR_RANGE_UNKNOWN = 0,
    VPFF_COLOR_RANGE_LIMITED = 1,
    VPFF_COLOR_RANGE_FULL = 2
} VPFFColorRange;

typedef enum {
    VPFF_COLOR_PRIMARIES_UNKNOWN = 0,
    VPFF_COLOR_PRIMARIES_BT709 = 1,
    VPFF_COLOR_PRIMARIES_BT2020 = 9
} VPFFColorPrimaries;

typedef enum {
    VPFF_COLOR_TRANSFER_UNKNOWN = 0,
    VPFF_COLOR_TRANSFER_BT709 = 1,
    VPFF_COLOR_TRANSFER_BT2020 = 14,
    VPFF_COLOR_TRANSFER_BT2020_12 = 15,
    VPFF_COLOR_TRANSFER_PQ = 16,
    VPFF_COLOR_TRANSFER_HLG = 18
} VPFFColorTransfer;

typedef enum {
    VPFF_COLOR_MATRIX_UNKNOWN = 0,
    VPFF_COLOR_MATRIX_BT709 = 1,
    VPFF_COLOR_MATRIX_BT2020_NONCONSTANT = 9
} VPFFColorMatrix;

typedef enum {
    VPFF_CHROMA_LOCATION_UNKNOWN = 0,
    VPFF_CHROMA_LOCATION_LEFT = 1,
    VPFF_CHROMA_LOCATION_CENTER = 2,
    VPFF_CHROMA_LOCATION_TOP_LEFT = 3
} VPFFChromaLocation;

typedef struct {
    int32_t num;
    int32_t den;
} VPFFRational;

typedef struct {
    VPFFTrackExtrasPresence presence;
    VPFFTrackDispositionFlags dispositions;
    /* 与event一样仅在同步callback返回前有效。 */
    const uint8_t *language;
    size_t language_size;
    VPFFTrackRole role;
    VPFFTrackService service;
    VPFFRational sample_aspect_ratio;
    VPFFColorRange color_range;
    VPFFColorPrimaries color_primaries;
    VPFFColorTransfer color_transfer;
    VPFFColorMatrix color_matrix;
    VPFFChromaLocation chroma_location;
    VPFFRational mastering_display_red_x;
    VPFFRational mastering_display_red_y;
    VPFFRational mastering_display_green_x;
    VPFFRational mastering_display_green_y;
    VPFFRational mastering_display_blue_x;
    VPFFRational mastering_display_blue_y;
    VPFFRational mastering_display_white_point_x;
    VPFFRational mastering_display_white_point_y;
    VPFFRational mastering_display_minimum_luminance;
    VPFFRational mastering_display_maximum_luminance;
    uint16_t maximum_content_light_level;
    uint16_t maximum_frame_average_light_level;
} VPFFTrackExtrasV1;

typedef struct {
    uint32_t version;
    uint32_t size;
    uint32_t video_track_offset;
    uint32_t audio_track_offset;
} VPFFDemuxEventExtras;

typedef struct {
    VPFFDemuxEventExtras header;
    VPFFTrackExtrasV1 video;
    VPFFTrackExtrasV1 audio;
} VPFFDemuxEventExtrasV1;

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
    /* VPFFFieldOrder 原始值；复用保留填充位以维持 ABI 不变。 */
    uint8_t field_order;
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

/* 选轨完成、任何 stream 被 discard 前得到的定长容器作用域事实。 */
typedef enum {
    VPFF_AUDIO_PRIMARY_SCOPE_NONE = 0,
    VPFF_AUDIO_PRIMARY_SCOPE_PROGRAM = 1,
    VPFF_AUDIO_PRIMARY_SCOPE_FORMAT_STREAM_TABLE = 2
} VPFFAudioPrimaryScope;

typedef enum {
    VPFF_AUDIO_PRIMARY_NONE = 0,
    VPFF_AUDIO_PRIMARY_EXPLICIT_MAIN = 1,
    VPFF_AUDIO_PRIMARY_SOLE_AUDIO = 2,
    VPFF_AUDIO_PRIMARY_UNIQUE_DEFAULT = 3
} VPFFAudioPrimaryBasis;

typedef struct {
    uint32_t version;
    VPFFAudioPrimaryScope scope;
    int32_t program_index;
    int32_t program_id;
    int32_t selected_stream_index;
    uint32_t audio_stream_count;
    uint32_t default_audio_stream_count;
    uint32_t explicit_main_stream_count;
    uint32_t unclassifiable_role_stream_count;
    VPFFAudioPrimaryBasis primary_basis;
} VPFFAudioPrimaryEvidenceV1;

typedef struct {
    VPFFDemuxEventExtras header;
    VPFFTrackExtrasV1 video;
    VPFFTrackExtrasV1 audio;
    uint8_t has_audio_primary_evidence;
    VPFFAudioPrimaryEvidenceV1 audio_primary_evidence;
} VPFFDemuxEventExtrasV2;

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
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrack, field_order) == 53, "VPFFTrack.field_order ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFTrack) == 80, "VPFFTrack size ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFRational) == 8, "VPFFRational size ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, presence) == 0,
                         "VPFFTrackExtrasV1.presence ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, language) == 16,
                         "VPFFTrackExtrasV1.language ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, role) == 32,
                         "VPFFTrackExtrasV1.role ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, sample_aspect_ratio) == 40,
                         "VPFFTrackExtrasV1.sample_aspect_ratio ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, mastering_display_red_x) == 68,
                         "VPFFTrackExtrasV1.mastering_display_red_x ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFTrackExtrasV1, maximum_content_light_level) == 148,
                         "VPFFTrackExtrasV1.maximum_content_light_level ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFTrackExtrasV1) == 152,
                         "VPFFTrackExtrasV1 size ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFDemuxEventExtras) == 16,
                         "VPFFDemuxEventExtras size ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtras, version) == 0,
                         "VPFFDemuxEventExtras.version ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtras, size) == 4,
                         "VPFFDemuxEventExtras.size ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtras, video_track_offset) == 8,
                         "VPFFDemuxEventExtras.video_track_offset ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtras, audio_track_offset) == 12,
                         "VPFFDemuxEventExtras.audio_track_offset ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtrasV1, header) == 0,
                         "VPFFDemuxEventExtrasV1.header ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtrasV1, video) == 16,
                         "VPFFDemuxEventExtrasV1.video ABI");
VPFF_DEMUX_STATIC_ASSERT(offsetof(VPFFDemuxEventExtrasV1, audio) == 168,
                         "VPFFDemuxEventExtrasV1.audio ABI");
VPFF_DEMUX_STATIC_ASSERT(sizeof(VPFFDemuxEventExtrasV1) == 320,
                         "VPFFDemuxEventExtrasV1 size ABI");
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
typedef void (*VPFFDemuxCallbackV2)(void *context, const VPFFDemuxEvent *event,
                                    const VPFFDemuxEventExtras *extras);

int32_t vp_ffmpeg_demuxer_create(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallback callback,
    void *context,
    VPDemuxer **out_demuxer
);
int32_t vp_ffmpeg_demuxer_create_v2(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallbackV2 callback,
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

typedef enum {
    VPFF_TRACK_EXTRAS_DEBUG_FULL_EVIDENCE = 1,
    VPFF_TRACK_EXTRAS_DEBUG_DEFAULT_ONLY = 2,
    VPFF_TRACK_EXTRAS_DEBUG_FORMAT_DRIFT = 3,
    VPFF_TRACK_EXTRAS_DEBUG_AUDIO_SERVICE_MAIN = 4,
    VPFF_TRACK_EXTRAS_DEBUG_SERVICE_CONFLICT = 5,
    VPFF_TRACK_EXTRAS_DEBUG_ZERO_MIN_LUMINANCE = 6,
    VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY = 7,
    VPFF_TRACK_EXTRAS_DEBUG_INVALID_CONTENT_LIGHT_LEVEL = 8,
    VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY_SUM = 9,
    VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_SERVICE_TOKEN = 10,
    VPFF_TRACK_EXTRAS_DEBUG_KARAOKE_SERVICE = 11,
    VPFF_TRACK_EXTRAS_DEBUG_MALFORMED_AUDIO_SERVICE = 12,
    VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_TOKEN = 13,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_SOLE = 14,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN = 15,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNIQUE_DEFAULT = 16,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_AMBIGUOUS = 17,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MULTI_DEFAULT = 18,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN_DEFAULT_COMPETITION = 19,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNKNOWN_OR_AUXILIARY = 20,
    VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_FORMAT_SCOPE = 21,
    VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_COMMENT = 22,
    VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_DUB = 23
} VPFFTrackExtrasDebugScenario;

/* 同步回调真实生产mapper，供测试直接约束证据映射与格式漂移。 */
int32_t vp_ffmpeg_demuxer_debug_emit_track_extras(
    VPFFTrackExtrasDebugScenario scenario,
    VPFFDemuxCallbackV2 callback,
    void *context
);

typedef enum {
    VPFF_PRIMARY_REFRESH_DEBUG_COMPETING_AUDIO = 1,
    VPFF_PRIMARY_REFRESH_DEBUG_DEFAULT_DRIFT = 2,
    VPFF_PRIMARY_REFRESH_DEBUG_SELECTED_REMOVED = 3,
    VPFF_PRIMARY_REFRESH_DEBUG_ROLE_DRIFT = 4
} VPFFPrimaryRefreshDebugScenario;

typedef struct {
    int32_t status;
    uint32_t initial_audio_count;
    uint32_t refreshed_audio_count;
    uint32_t discontinuity_count;
    VPFFAudioPrimaryBasis initial_basis;
    VPFFAudioPrimaryBasis refreshed_basis;
} VPFFPrimaryRefreshDebugResult;

int32_t vp_ffmpeg_demuxer_debug_refresh_audio_primary(
    VPFFPrimaryRefreshDebugScenario scenario,
    VPFFPrimaryRefreshDebugResult *out_result
);
#endif

#ifdef __cplusplus
}
#endif
