// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegDemuxer.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/log.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/mem.h>
#include <libavutil/time.h>
#pragma clang diagnostic pop

#define VPFF_MAX_URL_BYTES ((size_t)64 * 1024)
#define VPFF_MAX_EXTRADATA_BYTES ((size_t)1 * 1024 * 1024)
#define VPFF_MAX_PACKET_BYTES ((size_t)64 * 1024 * 1024)
#define VPFF_MAX_CODED_SIDE_DATA_ENTRIES 64
#define VPFF_MAX_CODED_SIDE_DATA_BYTES ((size_t)1 * 1024 * 1024)
#define VPFF_MAX_LANGUAGE_BYTES ((size_t)1024)
#define VPFF_MAX_CHANNELS 64
#define VPFF_PROTOCOL_WHITELIST "http,https,tcp,tls,crypto,data"
#define VPFF_BOOTSTRAP_MAX_PACKETS 64
#define VPFF_BOOTSTRAP_MAX_BYTES ((size_t)16 * 1024 * 1024)

typedef struct {
    VPFFTrack value;
    VPFFTrackExtrasV1 extras;
    uint8_t *extradata;
    uint8_t *language;
} VPFFOwnedTrack;

typedef struct {
    uint8_t has_program_id;
    int32_t selected_program_id;
    uint8_t has_audio_primary_evidence;
    VPFFAudioPrimaryEvidenceV1 audio_primary_evidence;
    VPFFOwnedTrack video;
    VPFFOwnedTrack audio;
} VPFFOwnedTrackSet;

typedef struct {
    AVBSFContext *context;
    AVCodecParameters *raw_key;
    AVCodecParameters *source_key;
} VPFFVideoFilter;

typedef struct {
    bool valid;
    bool is_default;
    bool is_unimpaired;
    uint64_t area;
    int64_t bitrate;
    int stream_index;
} VPFFVideoScore;

typedef struct {
    bool valid;
    bool is_default;
    bool is_unimpaired;
    int channel_count;
    int sample_rate;
    int64_t bitrate;
    int stream_index;
} VPFFAudioScore;

typedef struct {
    bool valid;
    bool has_video_media;
    bool has_audio_media;
    VPFFVideoScore video;
    VPFFAudioScore audio;
    int program_id;
    unsigned int program_index;
} VPFFProgramScore;

typedef struct {
    bool has_program_id;
    int32_t program_id;
    uint8_t has_audio_primary_evidence;
    VPFFAudioPrimaryEvidenceV1 audio_primary_evidence;
    int video_stream_index;
    int audio_stream_index;
} VPFFSelection;

typedef struct {
    VPFFDemuxErrorKind kind;
    VPFFDemuxErrorStage stage;
    int code;
} VPFFFailure;

typedef struct {
    AVPacket *packet;
    AVCodecParameters *parameters;
    AVRational time_base;
    size_t accounted_bytes;
} VPFFRetainedPacket;

typedef struct {
    int consumed;
    uint8_t *output;
    int output_size;
    int width;
    int height;
    int coded_width;
    int coded_height;
} VPFFBootstrapParserStep;

typedef int (*VPFFBootstrapReadFunction)(void *context, AVPacket *packet);
typedef int (*VPFFBootstrapParseFunction)(
    void *context,
    const uint8_t *data,
    int size,
    int64_t pts,
    int64_t dts,
    int64_t position,
    VPFFBootstrapParserStep *step
);

typedef struct {
    VPFFRetainedPacket packets[VPFF_BOOTSTRAP_MAX_PACKETS];
    size_t packet_count;
    size_t total_bytes;
    AVCodecParameters *initial_video_parameters;
    AVRational initial_video_time_base;
    AVCodecParameters *initial_audio_parameters;
    AVRational initial_audio_time_base;
    int parsed_width;
    int parsed_height;
    AVCodecParserContext *parser;
    AVCodecContext *codec_context;
} VPFFVideoBootstrap;

struct VPDemuxer {
    char *url;
    int64_t timeout_us;
    VPFFDemuxCallback callback;
    VPFFDemuxCallbackV2 callback_v2;
    void *context;
    atomic_bool cancelled;
    atomic_bool run_claimed;
    _Atomic int64_t deadline_us;
};

static pthread_once_t vpff_log_install_once = PTHREAD_ONCE_INIT;

static void vpff_silent_log_callback(
    void *av_class,
    int level,
    const char *format,
    va_list arguments
) {
    (void)av_class;
    (void)level;
    (void)format;
    (void)arguments;
}

static void vpff_install_silent_logging(void) {
    av_log_set_callback(vpff_silent_log_callback);
}

static int vpff_map_field_order(enum AVFieldOrder value, uint8_t *mapped) {
    switch (value) {
        case AV_FIELD_UNKNOWN:
            *mapped = VPFF_FIELD_ORDER_UNKNOWN;
            return 0;
        case AV_FIELD_PROGRESSIVE:
            *mapped = VPFF_FIELD_ORDER_PROGRESSIVE;
            return 0;
        case AV_FIELD_TT:
            *mapped = VPFF_FIELD_ORDER_TT;
            return 0;
        case AV_FIELD_BB:
            *mapped = VPFF_FIELD_ORDER_BB;
            return 0;
        case AV_FIELD_TB:
            *mapped = VPFF_FIELD_ORDER_TB;
            return 0;
        case AV_FIELD_BT:
            *mapped = VPFF_FIELD_ORDER_BT;
            return 0;
    }
    return AVERROR_INVALIDDATA;
}

static bool vpff_utf8_is_valid(const uint8_t *bytes, size_t size) {
    size_t index = 0;
    while (index < size) {
        uint8_t first = bytes[index++];
        if (first <= 0x7F) {
            continue;
        }

        size_t continuation_count;
        uint32_t scalar;
        if (first >= 0xC2 && first <= 0xDF) {
            continuation_count = 1;
            scalar = first & 0x1F;
        } else if (first >= 0xE0 && first <= 0xEF) {
            continuation_count = 2;
            scalar = first & 0x0F;
        } else if (first >= 0xF0 && first <= 0xF4) {
            continuation_count = 3;
            scalar = first & 0x07;
        } else {
            return false;
        }

        if (continuation_count > size - index) {
            return false;
        }
        for (size_t offset = 0; offset < continuation_count; offset += 1) {
            uint8_t next = bytes[index++];
            if ((next & 0xC0) != 0x80) {
                return false;
            }
            scalar = (scalar << 6) | (next & 0x3F);
        }

        if ((continuation_count == 2 && scalar < 0x800) ||
            (continuation_count == 3 && scalar < 0x10000) ||
            scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
            return false;
        }
    }
    return true;
}

static bool vpff_has_ascii_prefix_case_insensitive(
    const uint8_t *bytes,
    size_t size,
    const char *prefix,
    size_t prefix_size
) {
    if (bytes == NULL || size < prefix_size) {
        return false;
    }
    for (size_t index = 0; index < prefix_size; index += 1) {
        uint8_t character = bytes[index];
        if (character >= 'A' && character <= 'Z') {
            character = (uint8_t)(character + ('a' - 'A'));
        }
        if (character != (uint8_t)prefix[index]) {
            return false;
        }
    }
    return true;
}

static bool vpff_has_http_scheme(const uint8_t *bytes, size_t size) {
    static const char http[] = "http://";
    static const char https[] = "https://";
    return vpff_has_ascii_prefix_case_insensitive(bytes, size, http, sizeof(http) - 1) ||
           vpff_has_ascii_prefix_case_insensitive(bytes, size, https, sizeof(https) - 1);
}

static bool vpff_bounded_c_string_size(
    const char *value,
    size_t maximum_size,
    size_t *size
) {
    if (value == NULL || size == NULL) {
        return false;
    }
    for (size_t index = 0; index <= maximum_size; index += 1) {
        if (value[index] == '\0') {
            *size = index;
            return true;
        }
    }
    return false;
}

static void vpff_lowercase_ascii_scheme(char *url, size_t scheme_size) {
    for (size_t index = 0; index < scheme_size; index += 1) {
        if (url[index] >= 'A' && url[index] <= 'Z') {
            url[index] = (char)(url[index] + ('a' - 'A'));
        }
    }
}

static bool vpff_normalize_direct_child_scheme(char *url, size_t size) {
    static const char http[] = "http://";
    static const char https[] = "https://";
    static const char data[] = "data:";
    if (vpff_has_ascii_prefix_case_insensitive(
            (const uint8_t *)url,
            size,
            http,
            sizeof(http) - 1
        )) {
        vpff_lowercase_ascii_scheme(url, sizeof("http") - 1);
        return true;
    }
    if (vpff_has_ascii_prefix_case_insensitive(
            (const uint8_t *)url,
            size,
            https,
            sizeof(https) - 1
        )) {
        vpff_lowercase_ascii_scheme(url, sizeof("https") - 1);
        return true;
    }
    if (vpff_has_ascii_prefix_case_insensitive(
            (const uint8_t *)url,
            size,
            data,
            sizeof(data) - 1
        )) {
        vpff_lowercase_ascii_scheme(url, sizeof("data") - 1);
        return true;
    }
    return false;
}

static bool vpff_normalize_child_url(char *url, size_t size) {
    static const char crypto_plus[] = "crypto+";
    static const char crypto_colon[] = "crypto:";
    if (vpff_normalize_direct_child_scheme(url, size)) {
        return true;
    }

    size_t nested_offset;
    if (vpff_has_ascii_prefix_case_insensitive(
            (const uint8_t *)url,
            size,
            crypto_plus,
            sizeof(crypto_plus) - 1
        )) {
        nested_offset = sizeof(crypto_plus) - 1;
    } else if (vpff_has_ascii_prefix_case_insensitive(
                   (const uint8_t *)url,
                   size,
                   crypto_colon,
                   sizeof(crypto_colon) - 1
               )) {
        nested_offset = sizeof(crypto_colon) - 1;
    } else {
        return false;
    }

    vpff_lowercase_ascii_scheme(url, sizeof("crypto") - 1);
    return vpff_normalize_direct_child_scheme(
        url + nested_offset,
        size - nested_offset
    );
}

static bool vpff_option_is_enabled(const AVDictionary *options, const char *key) {
    const AVDictionaryEntry *entry = av_dict_get(options, key, NULL, 0);
    if (entry == NULL || entry->value == NULL) {
        return false;
    }
    return strcmp(entry->value, "0") != 0 && strcmp(entry->value, "false") != 0 &&
           strcmp(entry->value, "no") != 0;
}

static int vpff_interrupt(void *opaque);

static int vpff_io_open(
    AVFormatContext *format,
    AVIOContext **io,
    const char *url,
    int flags,
    AVDictionary **options
) {
    if (io == NULL) {
        return AVERROR(EACCES);
    }
    *io = NULL;
    if (format == NULL || url == NULL || format->opaque == NULL ||
        (flags & AVIO_FLAG_READ) == 0 || (flags & AVIO_FLAG_WRITE) != 0) {
        return AVERROR(EACCES);
    }

    size_t url_size = 0;
    if (!vpff_bounded_c_string_size(url, VPFF_MAX_URL_BYTES, &url_size)) {
        return AVERROR(EACCES);
    }
    char *normalized_url = malloc(url_size + 1);
    if (normalized_url == NULL) {
        return AVERROR(ENOMEM);
    }
    memcpy(normalized_url, url, url_size + 1);
    if (!vpff_normalize_child_url(normalized_url, url_size)) {
        free(normalized_url);
        return AVERROR(EACCES);
    }

    AVDictionary *local_options = NULL;
    AVDictionary **effective_options = options == NULL ? &local_options : options;
    if (vpff_option_is_enabled(*effective_options, "listen") ||
        av_dict_get(*effective_options, "listen_timeout", NULL, 0) != NULL) {
        av_dict_free(&local_options);
        free(normalized_url);
        return AVERROR(EACCES);
    }

    int result = av_dict_set(
        effective_options,
        "protocol_whitelist",
        VPFF_PROTOCOL_WHITELIST,
        0
    );
    if (result >= 0) {
        AVIOInterruptCB interrupt = {
            .callback = vpff_interrupt,
            .opaque = format->opaque,
        };
        result = avio_open2(
            io,
            normalized_url,
            flags,
            &interrupt,
            effective_options
        );
    }
    if (result >= 0 &&
        av_dict_get(*effective_options, "protocol_whitelist", NULL, 0) != NULL) {
        avio_closep(io);
        result = AVERROR_OPTION_NOT_FOUND;
    }
    if (result < 0 && *io != NULL) {
        avio_closep(io);
    }
    av_dict_free(&local_options);
    free(normalized_url);
    return result;
}

static bool vpff_is_cancelled(const VPDemuxer *demuxer) {
    return atomic_load_explicit(&demuxer->cancelled, memory_order_acquire);
}

static bool vpff_deadline_expired(const VPDemuxer *demuxer) {
    int64_t deadline = atomic_load_explicit(&demuxer->deadline_us, memory_order_acquire);
    return deadline > 0 && av_gettime_relative() >= deadline;
}

static int vpff_interrupt(void *opaque) {
    const VPDemuxer *demuxer = opaque;
    if (demuxer == NULL) {
        return 1;
    }
    return vpff_is_cancelled(demuxer) || vpff_deadline_expired(demuxer);
}

static void vpff_refresh_deadline(VPDemuxer *demuxer) {
    int64_t now = av_gettime_relative();
    int64_t deadline = now > INT64_MAX - demuxer->timeout_us
        ? INT64_MAX
        : now + demuxer->timeout_us;
    atomic_store_explicit(&demuxer->deadline_us, deadline, memory_order_release);
}

static void vpff_clear_deadline(VPDemuxer *demuxer) {
    atomic_store_explicit(&demuxer->deadline_us, 0, memory_order_release);
}

static void vpff_emit_event(
    VPDemuxer *demuxer,
    const VPFFDemuxEvent *event,
    const VPFFDemuxEventExtras *extras
) {
    if (demuxer->callback_v2 != NULL) {
        demuxer->callback_v2(demuxer->context, event, extras);
    } else {
        demuxer->callback(demuxer->context, event);
    }
}

static void vpff_emit_terminal(
    VPDemuxer *demuxer,
    VPFFDemuxEventKind kind,
    VPFFDemuxErrorKind error_kind,
    VPFFDemuxErrorStage error_stage,
    int error_code
) {
    VPFFDemuxEvent event = {0};
    event.kind = kind;
    event.error_kind = error_kind;
    event.error_stage = error_stage;
    event.ffmpeg_error = (int32_t)error_code;
    vpff_emit_event(demuxer, &event, NULL);
}

static void vpff_emit_tracks(
    VPDemuxer *demuxer,
    VPFFDemuxEventKind kind,
    VPFFDemuxDiscontinuityReason discontinuity_reason,
    const VPFFOwnedTrackSet *tracks
) {
    VPFFDemuxEvent event = {0};
    event.kind = kind;
    event.discontinuity_reason = discontinuity_reason;
    event.has_program_id = tracks->has_program_id;
    event.selected_program_id = tracks->selected_program_id;
    event.video = tracks->video.value;
    event.audio = tracks->audio.value;

    VPFFDemuxEventExtrasV2 extras = {0};
    extras.header.version = tracks->has_audio_primary_evidence ? 2 : VPFF_DEMUX_EVENT_EXTRAS_VERSION_1;
    extras.header.size = tracks->has_audio_primary_evidence
        ? (uint32_t)sizeof(VPFFDemuxEventExtrasV2)
        : (uint32_t)sizeof(VPFFDemuxEventExtrasV1);
    if (event.video.present) {
        extras.header.video_track_offset = (uint32_t)offsetof(
            VPFFDemuxEventExtrasV1,
            video
        );
        extras.video = tracks->video.extras;
    }
    if (event.audio.present) {
        extras.header.audio_track_offset = (uint32_t)offsetof(
            VPFFDemuxEventExtrasV1,
            audio
        );
        extras.audio = tracks->audio.extras;
    }
    extras.has_audio_primary_evidence = tracks->has_audio_primary_evidence;
    extras.audio_primary_evidence = tracks->audio_primary_evidence;
    vpff_emit_event(demuxer, &event, &extras.header);
}

static VPFFCodec vpff_codec(enum AVCodecID codec_id) {
    switch (codec_id) {
    case AV_CODEC_ID_H264:
        return VPFF_CODEC_H264;
    case AV_CODEC_ID_HEVC:
        return VPFF_CODEC_HEVC;
    case AV_CODEC_ID_AAC:
        return VPFF_CODEC_AAC;
    case AV_CODEC_ID_AC3:
        return VPFF_CODEC_AC3;
    case AV_CODEC_ID_EAC3:
        return VPFF_CODEC_EAC3;
    case AV_CODEC_ID_MP2:
        return VPFF_CODEC_MP2;
    case AV_CODEC_ID_MP1:
        return VPFF_CODEC_MP1;
    case AV_CODEC_ID_MP3:
        return VPFF_CODEC_MP3;
    default:
        return VPFF_CODEC_UNSUPPORTED;
    }
}

static bool vpff_is_supported_video(const AVCodecParameters *parameters) {
    return parameters != NULL && parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
           (parameters->codec_id == AV_CODEC_ID_H264 ||
            parameters->codec_id == AV_CODEC_ID_HEVC);
}

static bool vpff_is_supported_audio_codec(const AVCodecParameters *parameters) {
    if (parameters == NULL || parameters->codec_type != AVMEDIA_TYPE_AUDIO) {
        return false;
    }
    return parameters->codec_id == AV_CODEC_ID_AAC ||
           parameters->codec_id == AV_CODEC_ID_AC3 ||
           parameters->codec_id == AV_CODEC_ID_EAC3 ||
           parameters->codec_id == AV_CODEC_ID_MP2 ||
           parameters->codec_id == AV_CODEC_ID_MP1 ||
           parameters->codec_id == AV_CODEC_ID_MP3;
}

static bool vpff_channel_layout_is_bounded(const AVChannelLayout *layout) {
    if (layout == NULL || layout->nb_channels < 0 ||
        layout->nb_channels > VPFF_MAX_CHANNELS) {
        return false;
    }
    switch (layout->order) {
    case AV_CHANNEL_ORDER_UNSPEC:
    case AV_CHANNEL_ORDER_NATIVE:
    case AV_CHANNEL_ORDER_AMBISONIC:
        return true;
    case AV_CHANNEL_ORDER_CUSTOM:
        return layout->nb_channels == 0 || layout->u.map != NULL;
    default:
        return false;
    }
}

static bool vpff_is_supported_audio_layout(const AVCodecParameters *parameters) {
    if (parameters == NULL ||
        !vpff_channel_layout_is_bounded(&parameters->ch_layout) ||
        av_channel_layout_check(&parameters->ch_layout) != 1) {
        return false;
    }
    return parameters->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC ||
           parameters->ch_layout.order == AV_CHANNEL_ORDER_NATIVE;
}

static bool vpff_is_supported_audio(const AVCodecParameters *parameters) {
    return vpff_is_supported_audio_codec(parameters) &&
           vpff_is_supported_audio_layout(parameters);
}

static uint64_t vpff_video_area(const AVCodecParameters *parameters) {
    if (parameters->width <= 0 || parameters->height <= 0) {
        return 0;
    }
    return (uint64_t)(unsigned int)parameters->width *
           (uint64_t)(unsigned int)parameters->height;
}

static int64_t vpff_nonnegative_bitrate(const AVCodecParameters *parameters) {
    return parameters->bit_rate > 0 ? parameters->bit_rate : 0;
}

static bool vpff_stream_is_unimpaired(const AVStream *stream) {
    const int impairment = AV_DISPOSITION_HEARING_IMPAIRED |
                           AV_DISPOSITION_VISUAL_IMPAIRED |
                           AV_DISPOSITION_DESCRIPTIONS;
    return (stream->disposition & impairment) == 0;
}

static bool vpff_video_score_is_better(
    const VPFFVideoScore *left,
    const VPFFVideoScore *right
) {
    if (left->valid != right->valid) {
        return left->valid;
    }
    if (!left->valid) {
        return false;
    }
    if (left->is_default != right->is_default) {
        return left->is_default;
    }
    if (left->is_unimpaired != right->is_unimpaired) {
        return left->is_unimpaired;
    }
    if (left->area != right->area) {
        return left->area > right->area;
    }
    if (left->bitrate != right->bitrate) {
        return left->bitrate > right->bitrate;
    }
    return left->stream_index < right->stream_index;
}

static bool vpff_audio_score_is_better(
    const VPFFAudioScore *left,
    const VPFFAudioScore *right
) {
    if (left->valid != right->valid) {
        return left->valid;
    }
    if (!left->valid) {
        return false;
    }
    if (left->is_default != right->is_default) {
        return left->is_default;
    }
    if (left->is_unimpaired != right->is_unimpaired) {
        return left->is_unimpaired;
    }
    if (left->channel_count != right->channel_count) {
        return left->channel_count > right->channel_count;
    }
    if (left->sample_rate != right->sample_rate) {
        return left->sample_rate > right->sample_rate;
    }
    if (left->bitrate != right->bitrate) {
        return left->bitrate > right->bitrate;
    }
    return left->stream_index < right->stream_index;
}

static int vpff_compare_video_features(
    const VPFFVideoScore *left,
    const VPFFVideoScore *right
) {
    if (left->valid != right->valid) {
        return left->valid ? 1 : -1;
    }
    if (!left->valid) {
        return 0;
    }
    if (left->is_default != right->is_default) {
        return left->is_default ? 1 : -1;
    }
    if (left->is_unimpaired != right->is_unimpaired) {
        return left->is_unimpaired ? 1 : -1;
    }
    if (left->area != right->area) {
        return left->area > right->area ? 1 : -1;
    }
    if (left->bitrate != right->bitrate) {
        return left->bitrate > right->bitrate ? 1 : -1;
    }
    return 0;
}

static int vpff_compare_audio_features(
    const VPFFAudioScore *left,
    const VPFFAudioScore *right
) {
    if (left->valid != right->valid) {
        return left->valid ? 1 : -1;
    }
    if (!left->valid) {
        return 0;
    }
    if (left->is_default != right->is_default) {
        return left->is_default ? 1 : -1;
    }
    if (left->is_unimpaired != right->is_unimpaired) {
        return left->is_unimpaired ? 1 : -1;
    }
    if (left->channel_count != right->channel_count) {
        return left->channel_count > right->channel_count ? 1 : -1;
    }
    if (left->sample_rate != right->sample_rate) {
        return left->sample_rate > right->sample_rate ? 1 : -1;
    }
    if (left->bitrate != right->bitrate) {
        return left->bitrate > right->bitrate ? 1 : -1;
    }
    return 0;
}

static bool vpff_program_score_is_better(
    const VPFFProgramScore *left,
    const VPFFProgramScore *right
) {
    if (left->valid != right->valid) {
        return left->valid;
    }
    if (!left->valid) {
        return false;
    }

    int comparison = vpff_compare_video_features(&left->video, &right->video);
    if (comparison != 0) {
        return comparison > 0;
    }
    comparison = vpff_compare_audio_features(&left->audio, &right->audio);
    if (comparison != 0) {
        return comparison > 0;
    }
    if (left->program_id != right->program_id) {
        return left->program_id < right->program_id;
    }
    return left->program_index < right->program_index;
}

static unsigned int vpff_candidate_stream_count(
    const AVFormatContext *format,
    unsigned int program_index
) {
    if (format->nb_programs == 0) {
        return format->nb_streams;
    }
    return format->programs[program_index]->nb_stream_indexes;
}

static unsigned int vpff_candidate_stream_index(
    const AVFormatContext *format,
    unsigned int program_index,
    unsigned int position
) {
    if (format->nb_programs == 0) {
        return position;
    }
    return format->programs[program_index]->stream_index[position];
}

static int vpff_validate_stream_table(const AVFormatContext *format) {
    if ((format->nb_streams > 0 && format->streams == NULL) ||
        (format->nb_programs > 0 && format->programs == NULL) ||
        format->nb_streams > (unsigned int)INT_MAX) {
        return AVERROR(EOVERFLOW);
    }
    for (unsigned int index = 0; index < format->nb_streams; index += 1) {
        const AVStream *stream = format->streams[index];
        if (stream == NULL || stream->codecpar == NULL || stream->index != (int)index) {
            return AVERROR_INVALIDDATA;
        }
    }
    for (unsigned int program_index = 0;
         program_index < format->nb_programs;
         program_index += 1) {
        const AVProgram *program = format->programs[program_index];
        if (program == NULL ||
            (program->nb_stream_indexes > 0 && program->stream_index == NULL)) {
            return AVERROR_INVALIDDATA;
        }
        for (unsigned int position = 0;
             position < program->nb_stream_indexes;
             position += 1) {
            if (program->stream_index[position] >= format->nb_streams) {
                return AVERROR_INVALIDDATA;
            }
        }
    }
    return 0;
}

static VPFFProgramScore vpff_score_program(
    const AVFormatContext *format,
    unsigned int program_index
) {
    VPFFProgramScore score = {0};
    score.program_index = program_index;
    score.program_id = format->nb_programs == 0 ? 0 : format->programs[program_index]->id;

    unsigned int count = vpff_candidate_stream_count(format, program_index);
    for (unsigned int position = 0; position < count; position += 1) {
        unsigned int stream_index = vpff_candidate_stream_index(
            format,
            program_index,
            position
        );
        AVStream *stream = format->streams[stream_index];
        AVCodecParameters *parameters = stream->codecpar;
        if (parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
            score.has_video_media = true;
            if (vpff_is_supported_video(parameters)) {
                VPFFVideoScore candidate = {
                    .valid = true,
                    .is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0,
                    .is_unimpaired = vpff_stream_is_unimpaired(stream),
                    .area = vpff_video_area(parameters),
                    .bitrate = vpff_nonnegative_bitrate(parameters),
                    .stream_index = (int)stream_index,
                };
                if (vpff_video_score_is_better(&candidate, &score.video)) {
                    score.video = candidate;
                }
            }
        } else if (parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
            score.has_audio_media = true;
            if (vpff_is_supported_audio(parameters)) {
                VPFFAudioScore candidate = {
                    .valid = true,
                    .is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0,
                    .is_unimpaired = vpff_stream_is_unimpaired(stream),
                    .channel_count = parameters->ch_layout.nb_channels,
                    .sample_rate = parameters->sample_rate,
                    .bitrate = vpff_nonnegative_bitrate(parameters),
                    .stream_index = (int)stream_index,
                };
                if (vpff_audio_score_is_better(&candidate, &score.audio)) {
                    score.audio = candidate;
                }
            }
        }
    }
    score.valid = score.has_video_media || score.has_audio_media;
    return score;
}

static const AVDictionaryEntry *vpff_stream_metadata(const AVStream *stream, const char *key);
static bool vpff_map_role_metadata(const AVStream *stream, VPFFTrackRole *role);

static int vpff_build_audio_primary_evidence(
    AVFormatContext *format,
    const VPFFProgramScore *best,
    VPFFSelection *selection
) {
    if (format == NULL || best == NULL || selection == NULL ||
        selection->audio_stream_index < 0) {
        return AVERROR_INVALIDDATA;
    }
    VPFFAudioPrimaryEvidenceV1 evidence = {
        .version = 1,
        .scope = format->nb_programs > 0
            ? VPFF_AUDIO_PRIMARY_SCOPE_PROGRAM
            : VPFF_AUDIO_PRIMARY_SCOPE_FORMAT_STREAM_TABLE,
        .program_index = format->nb_programs > 0 ? (int32_t)best->program_index : -1,
        .program_id = format->nb_programs > 0 ? (int32_t)best->program_id : 0,
        .selected_stream_index = selection->audio_stream_index,
    };
    for (unsigned int table_index = 0; table_index < format->nb_streams; table_index += 1) {
        bool in_scope = format->nb_programs == 0;
        if (!in_scope) {
            AVProgram *program = format->programs[best->program_index];
            if (program == NULL || program->stream_index == NULL) return AVERROR_INVALIDDATA;
            for (unsigned int member = 0; member < program->nb_stream_indexes; member += 1) {
                if (program->stream_index[member] == table_index) { in_scope = true; break; }
            }
        }
        AVStream *stream = format->streams[table_index];
        if (!in_scope || stream == NULL || stream->codecpar == NULL ||
            stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        if (evidence.audio_stream_count == UINT32_MAX) return AVERROR_INVALIDDATA;
        evidence.audio_stream_count += 1;
        if ((stream->disposition & AV_DISPOSITION_DEFAULT) != 0) {
            if (evidence.default_audio_stream_count == UINT32_MAX) return AVERROR_INVALIDDATA;
            evidence.default_audio_stream_count += 1;
        }
        VPFFTrackRole role = VPFF_TRACK_ROLE_UNKNOWN;
        if (vpff_map_role_metadata(stream, &role)) {
            if (role == VPFF_TRACK_ROLE_MAIN) {
                if (evidence.explicit_main_stream_count == UINT32_MAX) return AVERROR_INVALIDDATA;
                evidence.explicit_main_stream_count += 1;
            }
        } else if (vpff_stream_metadata(stream, "role") != NULL) {
            if (evidence.unclassifiable_role_stream_count == UINT32_MAX) return AVERROR_INVALIDDATA;
            evidence.unclassifiable_role_stream_count += 1;
        }
    }
    if (evidence.audio_stream_count == 0) return AVERROR_INVALIDDATA;
    AVStream *selected = format->streams[selection->audio_stream_index];
    if (selected == NULL || selected->codecpar == NULL ||
        selected->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return AVERROR_INVALIDDATA;
    if (format->nb_programs > 0) {
        AVProgram *program = format->programs[best->program_index];
        bool selected_is_member = false;
        if (program == NULL || program->stream_index == NULL) return AVERROR_INVALIDDATA;
        for (unsigned int member = 0; member < program->nb_stream_indexes; member += 1) {
            if (program->stream_index[member] == (unsigned int)selection->audio_stream_index) {
                selected_is_member = true;
                break;
            }
        }
        if (!selected_is_member) return AVERROR_INVALIDDATA;
    }
    VPFFTrackRole selected_role = VPFF_TRACK_ROLE_UNKNOWN;
    bool selected_main = vpff_map_role_metadata(selected, &selected_role) &&
        selected_role == VPFF_TRACK_ROLE_MAIN;
    bool selected_default = (selected->disposition & AV_DISPOSITION_DEFAULT) != 0;
    if (evidence.unclassifiable_role_stream_count == 0 && selected_main &&
        evidence.explicit_main_stream_count == 1 &&
        (evidence.default_audio_stream_count == 0 ||
         (selected_default && evidence.default_audio_stream_count == 1))) {
        evidence.primary_basis = VPFF_AUDIO_PRIMARY_EXPLICIT_MAIN;
    } else if (evidence.unclassifiable_role_stream_count == 0 && !selected_main &&
               evidence.audio_stream_count == 1) {
        evidence.primary_basis = VPFF_AUDIO_PRIMARY_SOLE_AUDIO;
    } else if (evidence.unclassifiable_role_stream_count == 0 && !selected_main &&
               selected_default && evidence.default_audio_stream_count == 1 &&
               evidence.explicit_main_stream_count == 0) {
        evidence.primary_basis = VPFF_AUDIO_PRIMARY_UNIQUE_DEFAULT;
    }
    selection->has_audio_primary_evidence = 1;
    selection->audio_primary_evidence = evidence;
    return 0;
}

/* 刷新不重新选轨；只用原始 program/stream 身份在当前容器表复验 receipt。 */
static int vpff_refresh_audio_primary_evidence(
    AVFormatContext *format, const VPFFSelection *selection, VPFFSelection *refreshed
) {
    if (format == NULL || selection == NULL || refreshed == NULL) return AVERROR_INVALIDDATA;
    *refreshed = *selection;
    if (!selection->has_audio_primary_evidence) return 0;
    if (selection->audio_stream_index < 0 ||
        (unsigned int)selection->audio_stream_index >= format->nb_streams) return AVERROR_INVALIDDATA;
    VPFFProgramScore scope = {0};
    if (selection->has_program_id) {
        if (format->nb_programs == 0) return AVERROR_INVALIDDATA;
        bool found = false;
        for (unsigned int index = 0; index < format->nb_programs; index += 1) {
            AVProgram *program = format->programs[index];
            if (program != NULL && program->id == selection->program_id) {
                if (found) return AVERROR_INVALIDDATA;
                found = true;
                scope.program_index = index;
                scope.program_id = program->id;
            }
        }
        if (!found) return AVERROR_INVALIDDATA;
    } else if (format->nb_programs != 0) {
        return AVERROR_INVALIDDATA;
    }
    return vpff_build_audio_primary_evidence(format, &scope, refreshed);
}

static int vpff_select_streams(
    AVFormatContext *format,
    VPFFSelection *selection,
    VPFFFailure *failure
) {
    int result = vpff_validate_stream_table(format);
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_SELECTION;
        failure->code = result;
        return result;
    }

    unsigned int candidate_count = format->nb_programs == 0 ? 1 : format->nb_programs;
    VPFFProgramScore best = {0};
    for (unsigned int index = 0; index < candidate_count; index += 1) {
        VPFFProgramScore candidate = vpff_score_program(format, index);
        if (vpff_program_score_is_better(&candidate, &best)) {
            best = candidate;
        }
    }

    if (!best.valid) {
        result = AVERROR_STREAM_NOT_FOUND;
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_SELECTION;
        failure->code = result;
        return result;
    }
    if (best.has_video_media && !best.video.valid) {
        result = AVERROR(ENOTSUP);
        failure->kind = VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO;
        failure->stage = VPFF_DEMUX_STAGE_SELECTION;
        failure->code = result;
        return result;
    }
    if (best.has_audio_media && !best.audio.valid) {
        result = AVERROR(ENOTSUP);
        failure->kind = VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO;
        failure->stage = VPFF_DEMUX_STAGE_SELECTION;
        failure->code = result;
        return result;
    }

    selection->has_program_id = format->nb_programs > 0;
    selection->program_id = (int32_t)best.program_id;
    selection->video_stream_index = best.video.valid ? best.video.stream_index : -1;
    selection->audio_stream_index = best.audio.valid ? best.audio.stream_index : -1;
    if (selection->audio_stream_index >= 0) {
        result = vpff_build_audio_primary_evidence(format, &best, selection);
        if (result < 0) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_SELECTION;
            failure->code = result;
            return result;
        }
    }

    for (unsigned int index = 0; index < format->nb_programs; index += 1) {
        format->programs[index]->discard = index == best.program_index
            ? AVDISCARD_DEFAULT
            : AVDISCARD_ALL;
    }
    for (unsigned int index = 0; index < format->nb_streams; index += 1) {
        format->streams[index]->discard =
            (int)index == selection->video_stream_index ||
            (int)index == selection->audio_stream_index
            ? AVDISCARD_DEFAULT
            : AVDISCARD_ALL;
    }
    return 0;
}

static bool vpff_time_base_is_valid(AVRational time_base) {
    return time_base.num > 0 && time_base.den > 0;
}

static AVRational vpff_guess_frame_rate(
    AVFormatContext *format,
    AVStream *stream
) {
    if (format == NULL || stream == NULL) {
        return (AVRational){0, 0};
    }
    AVRational frame_rate = av_guess_frame_rate(format, stream, NULL);
    if (frame_rate.num <= 0 || frame_rate.den <= 0 ||
        (int64_t)frame_rate.num > INT32_MAX ||
        (int64_t)frame_rate.den > INT32_MAX) {
        return (AVRational){0, 0};
    }
    return frame_rate;
}

static bool vpff_extradata_is_valid(const uint8_t *data, int size) {
    return size >= 0 && (size_t)size <= VPFF_MAX_EXTRADATA_BYTES &&
           (size == 0 || data != NULL);
}

static bool vpff_coded_side_data_is_bounded(const AVCodecParameters *parameters) {
    if (parameters == NULL || parameters->nb_coded_side_data < 0 ||
        parameters->nb_coded_side_data > VPFF_MAX_CODED_SIDE_DATA_ENTRIES ||
        (parameters->nb_coded_side_data > 0 && parameters->coded_side_data == NULL)) {
        return false;
    }

    size_t total_size = 0;
    for (int index = 0; index < parameters->nb_coded_side_data; index += 1) {
        const AVPacketSideData *side_data = &parameters->coded_side_data[index];
        if (side_data->size > VPFF_MAX_CODED_SIDE_DATA_BYTES ||
            (side_data->size > 0 && side_data->data == NULL) ||
            side_data->size > VPFF_MAX_CODED_SIDE_DATA_BYTES - total_size) {
            return false;
        }
        total_size += side_data->size;
    }
    return true;
}

static bool vpff_parameters_are_bounded(const AVCodecParameters *parameters) {
    return parameters != NULL &&
           vpff_extradata_is_valid(parameters->extradata, parameters->extradata_size) &&
           vpff_coded_side_data_is_bounded(parameters) &&
           vpff_channel_layout_is_bounded(&parameters->ch_layout);
}

static bool vpff_side_data_is_valid(const AVPacketSideData *side_data) {
    return side_data == NULL ||
           (side_data->size <= VPFF_MAX_EXTRADATA_BYTES &&
            side_data->size <= (size_t)(INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) &&
            (side_data->size == 0 || side_data->data != NULL));
}

static bool vpff_packet_is_bounded(const AVPacket *packet) {
    if (packet == NULL || packet->size < 0 ||
        (size_t)packet->size > VPFF_MAX_PACKET_BYTES ||
        (packet->size > 0 && packet->data == NULL) ||
        packet->side_data_elems < 0 ||
        packet->side_data_elems > VPFF_MAX_CODED_SIDE_DATA_ENTRIES ||
        (packet->side_data_elems > 0 && packet->side_data == NULL)) {
        return false;
    }

    size_t total_side_data_size = 0;
    for (int index = 0; index < packet->side_data_elems; index += 1) {
        const AVPacketSideData *side_data = &packet->side_data[index];
        if (side_data->size > VPFF_MAX_CODED_SIDE_DATA_BYTES ||
            (side_data->size > 0 && side_data->data == NULL) ||
            side_data->size > VPFF_MAX_CODED_SIDE_DATA_BYTES - total_side_data_size) {
            return false;
        }
        total_side_data_size += side_data->size;
    }
    return true;
}

static bool vpff_video_dimensions_are_complete(const AVCodecParameters *parameters) {
    return vpff_is_supported_video(parameters) &&
           parameters->width > 0 && parameters->height > 0;
}

static int vpff_packet_footprint(const AVPacket *packet, size_t *footprint) {
    if (!vpff_packet_is_bounded(packet) || footprint == NULL) {
        return AVERROR_INVALIDDATA;
    }
    size_t total = (size_t)packet->size;
    for (int index = 0; index < packet->side_data_elems; index += 1) {
        size_t side_size = packet->side_data[index].size;
        if (side_size > SIZE_MAX - total) {
            return AVERROR_INVALIDDATA;
        }
        total += side_size;
    }
    *footprint = total;
    return 0;
}

static int vpff_size_add(size_t *total, size_t value) {
    if (total == NULL || value > SIZE_MAX - *total) {
        return AVERROR_INVALIDDATA;
    }
    *total += value;
    return 0;
}

static int vpff_parameter_footprint(
    const AVCodecParameters *parameters,
    size_t *footprint
) {
    if (!vpff_parameters_are_bounded(parameters) || footprint == NULL) {
        return AVERROR_INVALIDDATA;
    }

    size_t total = sizeof(*parameters);
    if (parameters->extradata_size > 0 &&
        vpff_size_add(
            &total,
            (size_t)parameters->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE
        ) < 0) {
        return AVERROR_INVALIDDATA;
    }
    if (parameters->nb_coded_side_data > 0) {
        size_t entry_count = (size_t)parameters->nb_coded_side_data;
        if (entry_count > SIZE_MAX / sizeof(*parameters->coded_side_data) ||
            vpff_size_add(
                &total,
                entry_count * sizeof(*parameters->coded_side_data)
            ) < 0) {
            return AVERROR_INVALIDDATA;
        }
        for (int index = 0; index < parameters->nb_coded_side_data; index += 1) {
            size_t size = parameters->coded_side_data[index].size;
            if (size > SIZE_MAX - AV_INPUT_BUFFER_PADDING_SIZE ||
                vpff_size_add(&total, size + AV_INPUT_BUFFER_PADDING_SIZE) < 0) {
                return AVERROR_INVALIDDATA;
            }
        }
    }
    if (parameters->ch_layout.order == AV_CHANNEL_ORDER_CUSTOM &&
        parameters->ch_layout.nb_channels > 0) {
        size_t channel_count = (size_t)parameters->ch_layout.nb_channels;
        if (channel_count > SIZE_MAX / sizeof(*parameters->ch_layout.u.map) ||
            vpff_size_add(
                &total,
                channel_count * sizeof(*parameters->ch_layout.u.map)
            ) < 0) {
            return AVERROR_INVALIDDATA;
        }
    }
    *footprint = total;
    return 0;
}

static size_t vpff_video_bootstrap_live_resource_count(
    const VPFFVideoBootstrap *bootstrap
) {
    if (bootstrap == NULL) {
        return 0;
    }
    size_t count = bootstrap->parser != NULL ? 1 : 0;
    count += bootstrap->codec_context != NULL ? 1 : 0;
    count += bootstrap->initial_video_parameters != NULL ? 1 : 0;
    count += bootstrap->initial_audio_parameters != NULL ? 1 : 0;
    for (size_t index = 0; index < bootstrap->packet_count; index += 1) {
        count += bootstrap->packets[index].packet != NULL ? 1 : 0;
        count += bootstrap->packets[index].parameters != NULL ? 1 : 0;
    }
    return count;
}

static void vpff_retained_packet_clear(VPFFRetainedPacket *retained) {
    if (retained == NULL) {
        return;
    }
    av_packet_free(&retained->packet);
    avcodec_parameters_free(&retained->parameters);
    memset(retained, 0, sizeof(*retained));
}

static size_t vpff_video_bootstrap_clear(VPFFVideoBootstrap *bootstrap) {
    if (bootstrap == NULL) {
        return 0;
    }
    for (size_t index = 0; index < bootstrap->packet_count; index += 1) {
        vpff_retained_packet_clear(&bootstrap->packets[index]);
    }
    avcodec_parameters_free(&bootstrap->initial_video_parameters);
    avcodec_parameters_free(&bootstrap->initial_audio_parameters);
    av_parser_close(bootstrap->parser);
    bootstrap->parser = NULL;
    avcodec_free_context(&bootstrap->codec_context);
    size_t residual = vpff_video_bootstrap_live_resource_count(bootstrap);
    memset(bootstrap, 0, sizeof(*bootstrap));
    return residual;
}

static int vpff_video_bootstrap_copy_initial(
    VPFFVideoBootstrap *bootstrap,
    const AVCodecParameters *source,
    AVCodecParameters **destination
) {
    size_t footprint = 0;
    int result = vpff_parameter_footprint(source, &footprint);
    if (result < 0 || bootstrap->total_bytes > VPFF_BOOTSTRAP_MAX_BYTES ||
        footprint > VPFF_BOOTSTRAP_MAX_BYTES - bootstrap->total_bytes) {
        return AVERROR_INVALIDDATA;
    }
    AVCodecParameters *copy = avcodec_parameters_alloc();
    if (copy == NULL) {
        return AVERROR(ENOMEM);
    }
    result = avcodec_parameters_copy(copy, source);
    if (result < 0) {
        avcodec_parameters_free(&copy);
        return result;
    }
    *destination = copy;
    bootstrap->total_bytes += footprint;
    return 0;
}

static int vpff_video_bootstrap_initialize(
    VPFFVideoBootstrap *bootstrap,
    AVFormatContext *format,
    const VPFFSelection *selection
) {
    if (bootstrap == NULL || format == NULL || selection == NULL ||
        selection->video_stream_index < 0 ||
        (unsigned int)selection->video_stream_index >= format->nb_streams) {
        return AVERROR_INVALIDDATA;
    }
    AVStream *video_stream = format->streams[selection->video_stream_index];
    if (video_stream == NULL || !vpff_is_supported_video(video_stream->codecpar) ||
        !vpff_parameters_are_bounded(video_stream->codecpar) ||
        !vpff_time_base_is_valid(video_stream->time_base)) {
        return AVERROR_INVALIDDATA;
    }
    const AVCodecParameters *parameters = video_stream->codecpar;
    bootstrap->parser = av_parser_init(parameters->codec_id);
    if (bootstrap->parser == NULL) {
        return AVERROR(ENOSYS);
    }
    bootstrap->codec_context = avcodec_alloc_context3(NULL);
    if (bootstrap->codec_context == NULL) {
        (void)vpff_video_bootstrap_clear(bootstrap);
        return AVERROR(ENOMEM);
    }
    int result = avcodec_parameters_to_context(
        bootstrap->codec_context,
        parameters
    );
    if (result < 0) {
        (void)vpff_video_bootstrap_clear(bootstrap);
        return result;
    }
    result = vpff_video_bootstrap_copy_initial(
        bootstrap,
        video_stream->codecpar,
        &bootstrap->initial_video_parameters
    );
    if (result >= 0) {
        bootstrap->initial_video_time_base = video_stream->time_base;
    }
    if (result >= 0 && selection->audio_stream_index >= 0) {
        if ((unsigned int)selection->audio_stream_index >= format->nb_streams) {
            result = AVERROR_INVALIDDATA;
        } else {
            AVStream *audio_stream = format->streams[selection->audio_stream_index];
            if (audio_stream == NULL || audio_stream->codecpar == NULL ||
                !vpff_time_base_is_valid(audio_stream->time_base)) {
                result = AVERROR_INVALIDDATA;
            } else {
                result = vpff_video_bootstrap_copy_initial(
                    bootstrap,
                    audio_stream->codecpar,
                    &bootstrap->initial_audio_parameters
                );
                if (result >= 0) {
                    bootstrap->initial_audio_time_base = audio_stream->time_base;
                }
            }
        }
    }
    if (result < 0) {
        (void)vpff_video_bootstrap_clear(bootstrap);
    }
    return result;
}

static int vpff_video_bootstrap_retain_with_footprint(
    VPFFVideoBootstrap *bootstrap,
    const AVPacket *packet,
    const AVStream *stream,
    size_t packet_footprint
) {
    if (bootstrap == NULL || stream == NULL || stream->codecpar == NULL ||
        !vpff_time_base_is_valid(stream->time_base) ||
        bootstrap->packet_count >= VPFF_BOOTSTRAP_MAX_PACKETS) {
        return AVERROR_INVALIDDATA;
    }
    size_t parameter_footprint = 0;
    int result = vpff_parameter_footprint(stream->codecpar, &parameter_footprint);
    size_t retained_footprint = packet_footprint;
    if (result < 0 || vpff_size_add(&retained_footprint, parameter_footprint) < 0 ||
        bootstrap->total_bytes > VPFF_BOOTSTRAP_MAX_BYTES ||
        retained_footprint > VPFF_BOOTSTRAP_MAX_BYTES - bootstrap->total_bytes) {
        return AVERROR_INVALIDDATA;
    }

    VPFFRetainedPacket retained = {0};
    retained.packet = av_packet_clone(packet);
    retained.parameters = avcodec_parameters_alloc();
    if (retained.packet == NULL || retained.parameters == NULL) {
        vpff_retained_packet_clear(&retained);
        return AVERROR(ENOMEM);
    }
    result = avcodec_parameters_copy(retained.parameters, stream->codecpar);
    if (result < 0) {
        vpff_retained_packet_clear(&retained);
        return result;
    }
    retained.time_base = stream->time_base;
    retained.accounted_bytes = retained_footprint;
    bootstrap->packets[bootstrap->packet_count] = retained;
    bootstrap->packet_count += 1;
    bootstrap->total_bytes += retained_footprint;
    return 0;
}

static int vpff_video_bootstrap_retain(
    VPFFVideoBootstrap *bootstrap,
    const AVPacket *packet,
    const AVStream *stream
) {
    size_t footprint = 0;
    int result = vpff_packet_footprint(packet, &footprint);
    return result < 0
        ? result
        : vpff_video_bootstrap_retain_with_footprint(
            bootstrap,
            packet,
            stream,
            footprint
        );
}

static int vpff_video_bootstrap_parse_ffmpeg(
    void *context,
    const uint8_t *data,
    int size,
    int64_t pts,
    int64_t dts,
    int64_t position,
    VPFFBootstrapParserStep *step
) {
    VPFFVideoBootstrap *bootstrap = context;
    if (bootstrap == NULL || bootstrap->parser == NULL ||
        bootstrap->codec_context == NULL || step == NULL) {
        return AVERROR_INVALIDDATA;
    }
    step->consumed = av_parser_parse2(
        bootstrap->parser,
        bootstrap->codec_context,
        &step->output,
        &step->output_size,
        data,
        size,
        pts,
        dts,
        position
    );
    step->width = bootstrap->parser->width;
    step->height = bootstrap->parser->height;
    step->coded_width = bootstrap->parser->coded_width;
    step->coded_height = bootstrap->parser->coded_height;
    return step->consumed < 0 ? step->consumed : 0;
}

static int vpff_video_bootstrap_parse(
    VPFFVideoBootstrap *bootstrap,
    const AVPacket *packet,
    VPFFBootstrapParseFunction parse,
    void *parse_context,
    bool *complete
) {
    if (bootstrap == NULL || bootstrap->parser == NULL ||
        bootstrap->codec_context == NULL || packet == NULL || parse == NULL ||
        complete == NULL || packet->size <= 0 ||
        (packet->size > 0 && packet->data == NULL)) {
        return AVERROR_INVALIDDATA;
    }

    const uint8_t *data = packet->data;
    int remaining = packet->size;
    bool zero_consumed_output = false;
    while (remaining > 0) {
        VPFFBootstrapParserStep step = {0};
        int consumed_offset = packet->size - remaining;
        if (packet->pos > INT64_MAX - (int64_t)consumed_offset) {
            return AVERROR_INVALIDDATA;
        }
        int result = parse(
            parse_context,
            data,
            remaining,
            packet->pts,
            packet->dts,
            packet->pos + consumed_offset,
            &step
        );
        if (result < 0 || step.consumed < 0 || step.consumed > remaining ||
            step.output_size < 0 ||
            (size_t)step.output_size > VPFF_MAX_PACKET_BYTES ||
            (step.output_size > 0 && step.output == NULL)) {
            return result < 0 ? result : AVERROR_INVALIDDATA;
        }
        if (step.consumed == 0 && step.output_size == 0) {
            return AVERROR_INVALIDDATA;
        }
        if (step.consumed == 0) {
            if (zero_consumed_output) {
                return AVERROR_INVALIDDATA;
            }
            zero_consumed_output = true;
            continue;
        }
        zero_consumed_output = false;
        data += step.consumed;
        remaining -= step.consumed;

        if (step.width > 0 && step.height > 0) {
            if (step.coded_width <= 0 || step.coded_height <= 0 ||
                step.width > step.coded_width || step.height > step.coded_height) {
                return AVERROR_INVALIDDATA;
            }
            bootstrap->parsed_width = step.width;
            bootstrap->parsed_height = step.height;
            *complete = true;
            return 0;
        }
    }
    *complete = false;
    return 0;
}

typedef struct {
    AVFormatContext *format;
    VPDemuxer *demuxer;
} VPFFBootstrapLiveReader;

static int vpff_video_bootstrap_read_live(void *context, AVPacket *packet) {
    VPFFBootstrapLiveReader *reader = context;
    if (reader == NULL || reader->format == NULL || reader->demuxer == NULL ||
        packet == NULL) {
        return AVERROR_INVALIDDATA;
    }
    vpff_refresh_deadline(reader->demuxer);
    int result;
    do {
        result = av_read_frame(reader->format, packet);
        if (result == AVERROR(EAGAIN) && !vpff_interrupt(reader->demuxer)) {
            av_usleep(1000);
        }
    } while (result == AVERROR(EAGAIN) && !vpff_interrupt(reader->demuxer));
    vpff_clear_deadline(reader->demuxer);
    return vpff_is_cancelled(reader->demuxer) ? AVERROR_EXIT : result;
}

static int vpff_video_bootstrap_collect(
    VPFFVideoBootstrap *bootstrap,
    AVFormatContext *format,
    const VPFFSelection *selection,
    AVPacket *input,
    VPFFBootstrapReadFunction read,
    void *read_context,
    VPFFBootstrapParseFunction parse,
    void *parse_context
) {
    if (bootstrap == NULL || format == NULL || selection == NULL || input == NULL ||
        read == NULL || parse == NULL) {
        return AVERROR_INVALIDDATA;
    }

    bool dimensions_complete = false;
    while (!dimensions_complete) {
        int result = read(read_context, input);
        if (result == AVERROR_EOF) {
            return AVERROR_INVALIDDATA;
        }
        if (result < 0) {
            return result;
        }
        if (input->stream_index < 0 ||
            (unsigned int)input->stream_index >= format->nb_streams) {
            return AVERROR_INVALIDDATA;
        }
        AVStream *packet_stream = format->streams[input->stream_index];
        if (packet_stream == NULL || packet_stream->codecpar == NULL ||
            packet_stream->index != input->stream_index) {
            return AVERROR_INVALIDDATA;
        }
        if (input->stream_index != selection->video_stream_index &&
            input->stream_index != selection->audio_stream_index) {
            packet_stream->discard = AVDISCARD_ALL;
            av_packet_unref(input);
            continue;
        }
        if (!vpff_packet_is_bounded(input)) {
            return AVERROR_INVALIDDATA;
        }
        result = vpff_video_bootstrap_retain(bootstrap, input, packet_stream);
        if (result < 0) {
            return result;
        }
        if (input->stream_index == selection->video_stream_index) {
            result = vpff_video_bootstrap_parse(
                bootstrap,
                input,
                parse,
                parse_context,
                &dimensions_complete
            );
            if (result < 0) {
                return result;
            }
        }
        av_packet_unref(input);
    }
    return 0;
}

static int vpff_video_bootstrap_fill_missing_dimensions(
    const VPFFVideoBootstrap *bootstrap,
    AVCodecParameters *parameters
) {
    if (bootstrap == NULL || !vpff_is_supported_video(parameters) ||
        bootstrap->parsed_width <= 0 || bootstrap->parsed_height <= 0) {
        return AVERROR_INVALIDDATA;
    }
    if (parameters->width <= 0) {
        parameters->width = bootstrap->parsed_width;
    }
    if (parameters->height <= 0) {
        parameters->height = bootstrap->parsed_height;
    }
    return parameters->width > 0 && parameters->height > 0
        ? 0
        : AVERROR_INVALIDDATA;
}

static int vpff_video_bootstrap_restore_stream(
    const VPFFVideoBootstrap *bootstrap,
    AVStream *stream,
    AVCodecParameters *parameters,
    AVRational time_base,
    bool is_video
) {
    if (bootstrap == NULL || stream == NULL || stream->codecpar == NULL ||
        parameters == NULL || !vpff_time_base_is_valid(time_base)) {
        return AVERROR_INVALIDDATA;
    }
    int result = 0;
    if (is_video) {
        result = vpff_video_bootstrap_fill_missing_dimensions(bootstrap, parameters);
    }
    if (result >= 0) {
        result = avcodec_parameters_copy(stream->codecpar, parameters);
    }
    if (result >= 0) {
        stream->time_base = time_base;
    }
    return result;
}

static int vpff_video_bootstrap_restore_initial(
    VPFFVideoBootstrap *bootstrap,
    AVFormatContext *format,
    const VPFFSelection *selection
) {
    if (bootstrap == NULL || format == NULL || selection == NULL ||
        selection->video_stream_index < 0 ||
        (unsigned int)selection->video_stream_index >= format->nb_streams) {
        return AVERROR_INVALIDDATA;
    }
    int result = vpff_video_bootstrap_restore_stream(
        bootstrap,
        format->streams[selection->video_stream_index],
        bootstrap->initial_video_parameters,
        bootstrap->initial_video_time_base,
        true
    );
    if (result >= 0 && selection->audio_stream_index >= 0) {
        if ((unsigned int)selection->audio_stream_index >= format->nb_streams) {
            return AVERROR_INVALIDDATA;
        }
        result = vpff_video_bootstrap_restore_stream(
            bootstrap,
            format->streams[selection->audio_stream_index],
            bootstrap->initial_audio_parameters,
            bootstrap->initial_audio_time_base,
            false
        );
    }
    return result;
}

typedef int (*VPFFBootstrapReplayFunction)(
    void *context,
    AVFormatContext *format,
    const VPFFSelection *selection,
    AVPacket *packet
);

static int vpff_video_bootstrap_replay(
    VPFFVideoBootstrap *bootstrap,
    AVFormatContext *format,
    const VPFFSelection *selection,
    VPFFBootstrapReplayFunction replay,
    void *replay_context
) {
    if (bootstrap == NULL || format == NULL || selection == NULL || replay == NULL) {
        return AVERROR_INVALIDDATA;
    }
    int result = 0;
    for (size_t index = 0; index < bootstrap->packet_count; index += 1) {
        VPFFRetainedPacket *retained = &bootstrap->packets[index];
        if (retained->packet == NULL || retained->parameters == NULL ||
            retained->packet->stream_index < 0 ||
            (unsigned int)retained->packet->stream_index >= format->nb_streams) {
            result = AVERROR_INVALIDDATA;
        } else {
            bool is_video = retained->packet->stream_index ==
                selection->video_stream_index;
            result = vpff_video_bootstrap_restore_stream(
                bootstrap,
                format->streams[retained->packet->stream_index],
                retained->parameters,
                retained->time_base,
                is_video
            );
        }
        if (result >= 0) {
            result = replay(
                replay_context,
                format,
                selection,
                retained->packet
            );
        }
        vpff_retained_packet_clear(retained);
        if (result < 0) {
            size_t residual = vpff_video_bootstrap_clear(bootstrap);
            return residual == 0 ? result : AVERROR_BUG;
        }
    }
    return vpff_video_bootstrap_clear(bootstrap) == 0 ? 0 : AVERROR_BUG;
}

static bool vpff_bytes_equal(
    const uint8_t *left,
    size_t left_size,
    const uint8_t *right,
    size_t right_size
) {
    return left_size == right_size &&
           (left_size == 0 ||
            (left != NULL && right != NULL && memcmp(left, right, left_size) == 0));
}

static bool vpff_channel_layouts_equal(
    const AVChannelLayout *left,
    const AVChannelLayout *right
) {
    if (!vpff_channel_layout_is_bounded(left) ||
        !vpff_channel_layout_is_bounded(right) ||
        left->order != right->order || left->nb_channels != right->nb_channels) {
        return false;
    }
    switch (left->order) {
    case AV_CHANNEL_ORDER_UNSPEC:
        return true;
    case AV_CHANNEL_ORDER_NATIVE:
    case AV_CHANNEL_ORDER_AMBISONIC:
        return left->u.mask == right->u.mask;
    case AV_CHANNEL_ORDER_CUSTOM:
        if (left->nb_channels < 0 ||
            (left->nb_channels > 0 && (left->u.map == NULL || right->u.map == NULL))) {
            return false;
        }
        for (int index = 0; index < left->nb_channels; index += 1) {
            if (left->u.map[index].id != right->u.map[index].id ||
                memcmp(
                    left->u.map[index].name,
                    right->u.map[index].name,
                    sizeof(left->u.map[index].name)
                ) != 0) {
                return false;
            }
        }
        return true;
    default:
        return false;
    }
}

static bool vpff_coded_side_data_equal(
    const AVCodecParameters *left,
    const AVCodecParameters *right
) {
    if (left->nb_coded_side_data != right->nb_coded_side_data ||
        left->nb_coded_side_data < 0) {
        return false;
    }
    if (left->nb_coded_side_data > 0 &&
        (left->coded_side_data == NULL || right->coded_side_data == NULL)) {
        return false;
    }
    for (int index = 0; index < left->nb_coded_side_data; index += 1) {
        const AVPacketSideData *left_side = &left->coded_side_data[index];
        const AVPacketSideData *right_side = &right->coded_side_data[index];
        if (left_side->type != right_side->type ||
            !vpff_bytes_equal(
                left_side->data,
                left_side->size,
                right_side->data,
                right_side->size
            )) {
            return false;
        }
    }
    return true;
}

static bool vpff_parameters_equal_except_extradata(
    const AVCodecParameters *left,
    const AVCodecParameters *right
) {
    return left->codec_type == right->codec_type &&
           left->codec_id == right->codec_id &&
           left->codec_tag == right->codec_tag &&
           vpff_coded_side_data_equal(left, right) &&
           left->format == right->format &&
           left->bit_rate == right->bit_rate &&
           left->bits_per_coded_sample == right->bits_per_coded_sample &&
           left->bits_per_raw_sample == right->bits_per_raw_sample &&
           left->profile == right->profile &&
           left->level == right->level &&
           left->width == right->width &&
           left->height == right->height &&
           left->sample_aspect_ratio.num == right->sample_aspect_ratio.num &&
           left->sample_aspect_ratio.den == right->sample_aspect_ratio.den &&
           left->framerate.num == right->framerate.num &&
           left->framerate.den == right->framerate.den &&
           left->field_order == right->field_order &&
           left->color_range == right->color_range &&
           left->color_primaries == right->color_primaries &&
           left->color_trc == right->color_trc &&
           left->color_space == right->color_space &&
           left->chroma_location == right->chroma_location &&
           left->video_delay == right->video_delay &&
           vpff_channel_layouts_equal(&left->ch_layout, &right->ch_layout) &&
           left->sample_rate == right->sample_rate &&
           left->block_align == right->block_align &&
           left->frame_size == right->frame_size &&
           left->initial_padding == right->initial_padding &&
           left->trailing_padding == right->trailing_padding &&
           left->seek_preroll == right->seek_preroll &&
           left->alpha_mode == right->alpha_mode;
}

static bool vpff_parameters_equal_effective(
    const AVCodecParameters *key,
    const AVCodecParameters *current,
    const AVPacketSideData *new_extradata
) {
    if (key == NULL || current == NULL ||
        !vpff_parameters_equal_except_extradata(key, current)) {
        return false;
    }
    const uint8_t *data = new_extradata == NULL
        ? current->extradata
        : new_extradata->data;
    size_t size = new_extradata == NULL
        ? (size_t)current->extradata_size
        : new_extradata->size;
    return vpff_bytes_equal(
        key->extradata,
        (size_t)key->extradata_size,
        data,
        size
    );
}

static int vpff_copy_effective_parameters(
    AVCodecParameters **output,
    const AVCodecParameters *source,
    const AVPacketSideData *new_extradata
) {
    if (output == NULL || !vpff_parameters_are_bounded(source) ||
        !vpff_side_data_is_valid(new_extradata)) {
        return AVERROR_INVALIDDATA;
    }

    AVCodecParameters *copy = avcodec_parameters_alloc();
    if (copy == NULL) {
        return AVERROR(ENOMEM);
    }
    int result = avcodec_parameters_copy(copy, source);
    if (result < 0) {
        avcodec_parameters_free(&copy);
        return result;
    }

    if (new_extradata != NULL) {
        av_freep(&copy->extradata);
        copy->extradata_size = 0;
        if (new_extradata->size > 0) {
            copy->extradata = av_mallocz(
                new_extradata->size + AV_INPUT_BUFFER_PADDING_SIZE
            );
            if (copy->extradata == NULL) {
                avcodec_parameters_free(&copy);
                return AVERROR(ENOMEM);
            }
            memcpy(copy->extradata, new_extradata->data, new_extradata->size);
            copy->extradata_size = (int)new_extradata->size;
        }
    }
    *output = copy;
    return 0;
}

static void vpff_video_filter_free(VPFFVideoFilter *filter) {
    av_bsf_free(&filter->context);
    avcodec_parameters_free(&filter->raw_key);
    avcodec_parameters_free(&filter->source_key);
}

static int vpff_video_filter_build(
    const AVCodecParameters *parameters,
    const AVCodecParameters *source_parameters,
    AVRational time_base,
    VPFFVideoFilter *output
) {
    if (!vpff_is_supported_video(parameters) || source_parameters == NULL ||
        !vpff_time_base_is_valid(time_base) ||
        !vpff_parameters_are_bounded(parameters) ||
        !vpff_parameters_are_bounded(source_parameters)) {
        return AVERROR_INVALIDDATA;
    }

    const char *name = parameters->codec_id == AV_CODEC_ID_H264
        ? "h264_mp4toannexb"
        : "hevc_mp4toannexb";
    const AVBitStreamFilter *definition = av_bsf_get_by_name(name);
    if (definition == NULL) {
        return AVERROR_BSF_NOT_FOUND;
    }

    VPFFVideoFilter built = {0};
    int result = av_bsf_alloc(definition, &built.context);
    if (result < 0) {
        return result;
    }
    result = avcodec_parameters_copy(built.context->par_in, parameters);
    if (result >= 0) {
        built.context->time_base_in = time_base;
        result = av_bsf_init(built.context);
    }
    if (result >= 0) {
        built.raw_key = avcodec_parameters_alloc();
        if (built.raw_key == NULL) {
            result = AVERROR(ENOMEM);
        } else {
            result = avcodec_parameters_copy(built.raw_key, parameters);
        }
    }
    if (result >= 0) {
        built.source_key = avcodec_parameters_alloc();
        if (built.source_key == NULL) {
            result = AVERROR(ENOMEM);
        } else {
            result = avcodec_parameters_copy(built.source_key, source_parameters);
        }
    }
    if (result >= 0 &&
        (!vpff_time_base_is_valid(built.context->time_base_out) ||
         !vpff_extradata_is_valid(
             built.context->par_out->extradata,
             built.context->par_out->extradata_size
         ))) {
        result = AVERROR_INVALIDDATA;
    }
    if (result < 0) {
        vpff_video_filter_free(&built);
        return result;
    }
    *output = built;
    return 0;
}

static bool vpff_metadata_token_equal(const char *value, const char *expected) {
    if (value == NULL || expected == NULL) {
        return false;
    }
    size_t value_size = 0;
    size_t expected_size = strlen(expected);
    if (!vpff_bounded_c_string_size(value, 64, &value_size) ||
        value_size != expected_size) {
        return false;
    }
    for (size_t index = 0; index < value_size; index += 1) {
        unsigned char actual = (unsigned char)value[index];
        unsigned char wanted = (unsigned char)expected[index];
        if (actual >= 'A' && actual <= 'Z') {
            actual = (unsigned char)(actual + ('a' - 'A'));
        }
        if (actual == '-' || actual == ' ') {
            actual = '_';
        }
        if (actual != wanted) {
            return false;
        }
    }
    return true;
}

static const AVDictionaryEntry *vpff_stream_metadata(
    const AVStream *stream,
    const char *key
) {
    return stream == NULL ? NULL : av_dict_get(stream->metadata, key, NULL, 0);
}

static bool vpff_map_role_metadata(const AVStream *stream, VPFFTrackRole *role) {
    const AVDictionaryEntry *entry = vpff_stream_metadata(stream, "role");
    if (entry == NULL) {
        return false;
    }
    if (vpff_metadata_token_equal(entry->value, "main")) {
        *role = VPFF_TRACK_ROLE_MAIN;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "alternate")) {
        *role = VPFF_TRACK_ROLE_ALTERNATE;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "commentary")) {
        *role = VPFF_TRACK_ROLE_COMMENTARY;
        return true;
    }
    return false;
}

static bool vpff_map_service_metadata(
    const AVStream *stream,
    const char *key,
    VPFFTrackService *service
) {
    const AVDictionaryEntry *entry = vpff_stream_metadata(stream, key);
    if (entry == NULL) {
        return false;
    }
    if (vpff_metadata_token_equal(entry->value, "independent_main")) {
        *service = VPFF_TRACK_SERVICE_INDEPENDENT_MAIN;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "associated")) {
        *service = VPFF_TRACK_SERVICE_ASSOCIATED;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "dvs")) {
        *service = VPFF_TRACK_SERVICE_DVS;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "dependent")) {
        *service = VPFF_TRACK_SERVICE_DEPENDENT;
        return true;
    }
    if (vpff_metadata_token_equal(entry->value, "joc")) {
        *service = VPFF_TRACK_SERVICE_JOC;
        return true;
    }
    return false;
}

typedef struct {
    bool has_value;
    bool conflicts;
    VPFFTrackService value;
} VPFFServiceEvidence;

static void vpff_add_service_evidence(
    VPFFServiceEvidence *evidence,
    VPFFTrackService value
) {
    if (!evidence->has_value) {
        evidence->has_value = true;
        evidence->value = value;
    } else if (evidence->value != value) {
        evidence->conflicts = true;
    }
}

static bool vpff_map_audio_service(
    enum AVAudioServiceType source,
    VPFFTrackService *service
) {
    switch (source) {
    case AV_AUDIO_SERVICE_TYPE_MAIN:
        *service = VPFF_TRACK_SERVICE_INDEPENDENT_MAIN;
        return true;
    case AV_AUDIO_SERVICE_TYPE_VISUALLY_IMPAIRED:
        *service = VPFF_TRACK_SERVICE_DVS;
        return true;
    case AV_AUDIO_SERVICE_TYPE_EFFECTS:
    case AV_AUDIO_SERVICE_TYPE_HEARING_IMPAIRED:
    case AV_AUDIO_SERVICE_TYPE_DIALOGUE:
    case AV_AUDIO_SERVICE_TYPE_COMMENTARY:
    case AV_AUDIO_SERVICE_TYPE_EMERGENCY:
    case AV_AUDIO_SERVICE_TYPE_VOICE_OVER:
        *service = VPFF_TRACK_SERVICE_ASSOCIATED;
        return true;
    case AV_AUDIO_SERVICE_TYPE_KARAOKE:
    case AV_AUDIO_SERVICE_TYPE_NB:
        return false;
    }
    return false;
}

static int vpff_read_audio_service_type(
    const AVCodecParameters *parameters,
    enum AVAudioServiceType *service_type,
    bool *present
) {
    if (parameters == NULL || service_type == NULL || present == NULL) {
        return AVERROR_INVALIDDATA;
    }
    *present = false;
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_AUDIO_SERVICE_TYPE
    );
    if (side_data == NULL) {
        return 0;
    }
    if (side_data->data == NULL || side_data->size < sizeof(*service_type)) {
        return AVERROR_INVALIDDATA;
    }
    memcpy(service_type, side_data->data, sizeof(*service_type));
    if (*service_type < AV_AUDIO_SERVICE_TYPE_MAIN ||
        *service_type >= AV_AUDIO_SERVICE_TYPE_NB) {
        return AVERROR_INVALIDDATA;
    }
    *present = true;
    return 0;
}

static VPFFTrackDispositionFlags vpff_map_dispositions(int dispositions) {
    VPFFTrackDispositionFlags mapped = 0;
    if ((dispositions & AV_DISPOSITION_DEFAULT) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_DEFAULT;
    }
    if ((dispositions & AV_DISPOSITION_FORCED) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_FORCED;
    }
    if ((dispositions & AV_DISPOSITION_HEARING_IMPAIRED) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_HEARING_IMPAIRED;
    }
    if ((dispositions & AV_DISPOSITION_VISUAL_IMPAIRED) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_VISUAL_IMPAIRED;
    }
    if ((dispositions & AV_DISPOSITION_COMMENT) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_COMMENTARY;
    }
    if ((dispositions & AV_DISPOSITION_DEPENDENT) != 0) {
        mapped |= VPFF_TRACK_DISPOSITION_DEPENDENT;
    }
    return mapped;
}

static void vpff_map_color_range(
    enum AVColorRange value,
    VPFFTrackExtrasV1 *extras
) {
    if (value == AVCOL_RANGE_MPEG) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE;
        extras->color_range = VPFF_COLOR_RANGE_LIMITED;
    } else if (value == AVCOL_RANGE_JPEG) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE;
        extras->color_range = VPFF_COLOR_RANGE_FULL;
    }
}

static void vpff_map_color_primaries(
    enum AVColorPrimaries value,
    VPFFTrackExtrasV1 *extras
) {
    if (value == AVCOL_PRI_BT709) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES;
        extras->color_primaries = VPFF_COLOR_PRIMARIES_BT709;
    } else if (value == AVCOL_PRI_BT2020) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES;
        extras->color_primaries = VPFF_COLOR_PRIMARIES_BT2020;
    }
}

static void vpff_map_color_transfer(
    enum AVColorTransferCharacteristic value,
    VPFFTrackExtrasV1 *extras
) {
    if (value == AVCOL_TRC_BT709) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER;
        extras->color_transfer = VPFF_COLOR_TRANSFER_BT709;
    } else if (value == AVCOL_TRC_BT2020_10) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER;
        extras->color_transfer = VPFF_COLOR_TRANSFER_BT2020;
    } else if (value == AVCOL_TRC_BT2020_12) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER;
        extras->color_transfer = VPFF_COLOR_TRANSFER_BT2020_12;
    } else if (value == AVCOL_TRC_SMPTE2084) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER;
        extras->color_transfer = VPFF_COLOR_TRANSFER_PQ;
    } else if (value == AVCOL_TRC_ARIB_STD_B67) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER;
        extras->color_transfer = VPFF_COLOR_TRANSFER_HLG;
    }
}

static void vpff_map_color_matrix(
    enum AVColorSpace value,
    VPFFTrackExtrasV1 *extras
) {
    if (value == AVCOL_SPC_BT709) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX;
        extras->color_matrix = VPFF_COLOR_MATRIX_BT709;
    } else if (value == AVCOL_SPC_BT2020_NCL) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX;
        extras->color_matrix = VPFF_COLOR_MATRIX_BT2020_NONCONSTANT;
    }
}

static void vpff_map_chroma_location(
    enum AVChromaLocation value,
    VPFFTrackExtrasV1 *extras
) {
    if (value == AVCHROMA_LOC_LEFT) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION;
        extras->chroma_location = VPFF_CHROMA_LOCATION_LEFT;
    } else if (value == AVCHROMA_LOC_CENTER) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION;
        extras->chroma_location = VPFF_CHROMA_LOCATION_CENTER;
    } else if (value == AVCHROMA_LOC_TOPLEFT) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION;
        extras->chroma_location = VPFF_CHROMA_LOCATION_TOP_LEFT;
    }
}

static bool vpff_rational_is_nonnegative(AVRational value) {
    return value.num >= 0 && value.den > 0;
}

static bool vpff_chromaticity_pair_is_valid(AVRational x, AVRational y) {
    if (!vpff_rational_is_nonnegative(x) ||
        !vpff_rational_is_nonnegative(y) ||
        x.num > x.den || y.num > y.den) {
        return false;
    }
    int64_t scaled_x;
    int64_t scaled_y;
    int64_t scaled_unit;
    int64_t sum;
    return !__builtin_mul_overflow((int64_t)x.num, (int64_t)y.den, &scaled_x) &&
           !__builtin_mul_overflow((int64_t)y.num, (int64_t)x.den, &scaled_y) &&
           !__builtin_mul_overflow((int64_t)x.den, (int64_t)y.den, &scaled_unit) &&
           !__builtin_add_overflow(scaled_x, scaled_y, &sum) &&
           sum <= scaled_unit;
}

static VPFFRational vpff_public_rational(AVRational value) {
    return (VPFFRational){.num = value.num, .den = value.den};
}

static int vpff_map_mastering_display(
    const AVCodecParameters *parameters,
    VPFFTrackExtrasV1 *extras
) {
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA
    );
    if (side_data == NULL) {
        return 0;
    }
    if (side_data->data == NULL ||
        side_data->size < sizeof(AVMasteringDisplayMetadata)) {
        return AVERROR_INVALIDDATA;
    }

    AVMasteringDisplayMetadata metadata;
    memcpy(&metadata, side_data->data, sizeof(metadata));
    if ((metadata.has_primaries != 0 && metadata.has_primaries != 1) ||
        (metadata.has_luminance != 0 && metadata.has_luminance != 1)) {
        return AVERROR_INVALIDDATA;
    }
    if (!metadata.has_primaries || !metadata.has_luminance) {
        return 0;
    }
    const AVRational chromaticities[] = {
        metadata.display_primaries[0][0], metadata.display_primaries[0][1],
        metadata.display_primaries[1][0], metadata.display_primaries[1][1],
        metadata.display_primaries[2][0], metadata.display_primaries[2][1],
        metadata.white_point[0], metadata.white_point[1],
    };
    for (size_t index = 0;
         index < sizeof(chromaticities) / sizeof(chromaticities[0]);
         index += 2) {
        if (!vpff_chromaticity_pair_is_valid(
                chromaticities[index],
                chromaticities[index + 1]
            )) {
            return AVERROR_INVALIDDATA;
        }
    }
    if (!vpff_rational_is_nonnegative(metadata.min_luminance) ||
        !vpff_rational_is_nonnegative(metadata.max_luminance) ||
        metadata.max_luminance.num <= 0 ||
        av_cmp_q(metadata.min_luminance, metadata.max_luminance) > 0) {
        return AVERROR_INVALIDDATA;
    }

    extras->presence |= VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY;
    extras->mastering_display_red_x = vpff_public_rational(chromaticities[0]);
    extras->mastering_display_red_y = vpff_public_rational(chromaticities[1]);
    extras->mastering_display_green_x = vpff_public_rational(chromaticities[2]);
    extras->mastering_display_green_y = vpff_public_rational(chromaticities[3]);
    extras->mastering_display_blue_x = vpff_public_rational(chromaticities[4]);
    extras->mastering_display_blue_y = vpff_public_rational(chromaticities[5]);
    extras->mastering_display_white_point_x = vpff_public_rational(chromaticities[6]);
    extras->mastering_display_white_point_y = vpff_public_rational(chromaticities[7]);
    extras->mastering_display_minimum_luminance = vpff_public_rational(
        metadata.min_luminance
    );
    extras->mastering_display_maximum_luminance = vpff_public_rational(
        metadata.max_luminance
    );
    return 0;
}

static int vpff_map_content_light_level(
    const AVCodecParameters *parameters,
    VPFFTrackExtrasV1 *extras
) {
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL
    );
    if (side_data == NULL) {
        return 0;
    }
    if (side_data->data == NULL || side_data->size < sizeof(AVContentLightMetadata)) {
        return AVERROR_INVALIDDATA;
    }
    AVContentLightMetadata metadata;
    memcpy(&metadata, side_data->data, sizeof(metadata));
    if (metadata.MaxCLL > UINT16_MAX || metadata.MaxFALL > UINT16_MAX ||
        metadata.MaxFALL > metadata.MaxCLL) {
        return AVERROR_INVALIDDATA;
    }
    extras->presence |= VPFF_TRACK_EXTRAS_HAS_CONTENT_LIGHT_LEVEL;
    extras->maximum_content_light_level = (uint16_t)metadata.MaxCLL;
    extras->maximum_frame_average_light_level = (uint16_t)metadata.MaxFALL;
    return 0;
}

static int vpff_map_track_extras(
    VPFFTrackExtrasV1 *extras,
    const AVStream *stream,
    const AVCodecParameters *parameters
) {
    if (extras == NULL || stream == NULL || parameters == NULL) {
        return AVERROR_INVALIDDATA;
    }
    memset(extras, 0, sizeof(*extras));
    extras->presence = VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS;
    extras->dispositions = vpff_map_dispositions(stream->disposition);

    const AVDictionaryEntry *language = vpff_stream_metadata(stream, "language");
    if (language != NULL && language->value != NULL && language->value[0] != '\0') {
        size_t language_size = 0;
        if (!vpff_bounded_c_string_size(
                language->value,
                VPFF_MAX_LANGUAGE_BYTES,
                &language_size
            ) ||
            !vpff_utf8_is_valid((const uint8_t *)language->value, language_size)) {
            return AVERROR_INVALIDDATA;
        }
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_LANGUAGE;
        extras->language = (const uint8_t *)language->value;
        extras->language_size = language_size;
    }

    bool has_role = vpff_map_role_metadata(stream, &extras->role);
    if (!has_role && vpff_stream_metadata(stream, "role") != NULL) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT;
    }
    VPFFServiceEvidence service_evidence = {0};
    VPFFTrackService metadata_service = VPFF_TRACK_SERVICE_UNKNOWN;
    bool has_service_metadata = vpff_stream_metadata(stream, "service") != NULL;
    if (vpff_map_service_metadata(stream, "service", &metadata_service)) {
        vpff_add_service_evidence(&service_evidence, metadata_service);
    } else if (has_service_metadata) {
        // 元数据明确存在但token未知，必须保留为不可分类，不能折叠成absent。
        service_evidence.conflicts = true;
    }
    bool has_service_type_metadata =
        vpff_stream_metadata(stream, "service_type") != NULL;
    if (vpff_map_service_metadata(stream, "service_type", &metadata_service)) {
        vpff_add_service_evidence(&service_evidence, metadata_service);
    } else if (has_service_type_metadata) {
        service_evidence.conflicts = true;
    }
    if (!has_role && (extras->presence & VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT) == 0 &&
        (stream->disposition & AV_DISPOSITION_COMMENT) != 0) {
        extras->role = VPFF_TRACK_ROLE_COMMENTARY;
        has_role = true;
    } else if (!has_role && (extras->presence & VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT) == 0 &&
        (stream->disposition & AV_DISPOSITION_DUB) != 0) {
        extras->role = VPFF_TRACK_ROLE_ALTERNATE;
        has_role = true;
    }

    if (parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
        enum AVAudioServiceType audio_service = AV_AUDIO_SERVICE_TYPE_MAIN;
        bool has_audio_service = false;
        int result = vpff_read_audio_service_type(
            parameters,
            &audio_service,
            &has_audio_service
        );
        if (result < 0) {
            return result;
        }
        if (has_audio_service) {
            if (!has_role && (extras->presence & VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT) == 0 &&
                audio_service == AV_AUDIO_SERVICE_TYPE_COMMENTARY) {
                extras->role = VPFF_TRACK_ROLE_COMMENTARY;
                has_role = true;
            }
            VPFFTrackService audio_service_evidence = VPFF_TRACK_SERVICE_UNKNOWN;
            if (vpff_map_audio_service(audio_service, &audio_service_evidence)) {
                vpff_add_service_evidence(
                    &service_evidence,
                    audio_service_evidence
                );
            } else {
                // Karaoke等合法但当前不支持的服务类型是不可分类证据。
                service_evidence.conflicts = true;
            }
        }
        if (parameters->codec_id == AV_CODEC_ID_EAC3 &&
            parameters->profile == AV_PROFILE_EAC3_DDP_ATMOS) {
            vpff_add_service_evidence(&service_evidence, VPFF_TRACK_SERVICE_JOC);
        }
        if ((stream->disposition & AV_DISPOSITION_DEPENDENT) != 0) {
            vpff_add_service_evidence(
                &service_evidence,
                VPFF_TRACK_SERVICE_DEPENDENT
            );
        }
    }
    if (has_role) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_ROLE;
    }
    if (service_evidence.has_value && !service_evidence.conflicts) {
        extras->service = service_evidence.value;
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_SERVICE;
    } else if (service_evidence.conflicts) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT;
    }

    if (parameters->codec_type != AVMEDIA_TYPE_VIDEO) {
        return 0;
    }
    if (parameters->sample_aspect_ratio.num > 0 &&
        parameters->sample_aspect_ratio.den > 0) {
        extras->presence |= VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO;
        extras->sample_aspect_ratio = vpff_public_rational(
            parameters->sample_aspect_ratio
        );
    }
    vpff_map_color_range(parameters->color_range, extras);
    vpff_map_color_primaries(parameters->color_primaries, extras);
    vpff_map_color_transfer(parameters->color_trc, extras);
    vpff_map_color_matrix(parameters->color_space, extras);
    vpff_map_chroma_location(parameters->chroma_location, extras);
    int result = vpff_map_mastering_display(parameters, extras);
    return result < 0 ? result : vpff_map_content_light_level(parameters, extras);
}

static void vpff_owned_track_clear(VPFFOwnedTrack *track) {
    if (track == NULL) {
        return;
    }
    free(track->extradata);
    free(track->language);
    memset(track, 0, sizeof(*track));
}

static void vpff_owned_track_set_clear(VPFFOwnedTrackSet *tracks) {
    if (tracks == NULL) {
        return;
    }
    vpff_owned_track_clear(&tracks->video);
    vpff_owned_track_clear(&tracks->audio);
    tracks->has_program_id = 0;
    tracks->selected_program_id = 0;
}

static int vpff_copy_borrowed_track(
    VPFFOwnedTrack *destination,
    const VPFFOwnedTrack *source
) {
    if (destination == NULL || source == NULL) {
        return AVERROR_INVALIDDATA;
    }
    VPFFOwnedTrack built = {
        .value = source->value,
        .extras = source->extras,
    };
    built.value.extradata = NULL;
    built.extras.language = NULL;

    if (source->value.extradata_size > 0) {
        if (source->value.extradata == NULL ||
            source->value.extradata_size > VPFF_MAX_EXTRADATA_BYTES) {
            return AVERROR_INVALIDDATA;
        }
        built.extradata = malloc(source->value.extradata_size);
        if (built.extradata == NULL) {
            return AVERROR(ENOMEM);
        }
        memcpy(
            built.extradata,
            source->value.extradata,
            source->value.extradata_size
        );
        built.value.extradata = built.extradata;
    }
    if ((source->extras.presence & VPFF_TRACK_EXTRAS_HAS_LANGUAGE) != 0) {
        if (source->extras.language == NULL || source->extras.language_size == 0 ||
            source->extras.language_size > VPFF_MAX_LANGUAGE_BYTES) {
            vpff_owned_track_clear(&built);
            return AVERROR_INVALIDDATA;
        }
        built.language = malloc(source->extras.language_size);
        if (built.language == NULL) {
            vpff_owned_track_clear(&built);
            return AVERROR(ENOMEM);
        }
        memcpy(
            built.language,
            source->extras.language,
            source->extras.language_size
        );
        built.extras.language = built.language;
    } else if (source->extras.language != NULL || source->extras.language_size != 0) {
        vpff_owned_track_clear(&built);
        return AVERROR_INVALIDDATA;
    }
    *destination = built;
    return 0;
}

static int vpff_fill_video_track(
    VPFFOwnedTrack *track,
    const AVStream *stream,
    const AVCodecParameters *parameters,
    AVRational time_base,
    AVRational frame_rate
) {
    if (track == NULL || stream == NULL || stream->codecpar == NULL ||
        !vpff_is_supported_video(parameters) ||
        !vpff_time_base_is_valid(time_base) || stream->index < 0 ||
        parameters->width <= 0 || parameters->height <= 0 ||
        parameters->video_delay < 0 ||
        !vpff_parameters_are_bounded(parameters)) {
        return AVERROR_INVALIDDATA;
    }

    VPFFOwnedTrack built = {0};
    built.value.present = 1;
    built.value.stream_index = (int32_t)stream->index;
    built.value.codec = vpff_codec(parameters->codec_id);
    built.value.time_base_num = time_base.num;
    built.value.time_base_den = time_base.den;
    if (frame_rate.num > 0 && frame_rate.den > 0) {
        built.value.frame_rate_num = frame_rate.num;
        built.value.frame_rate_den = frame_rate.den;
    }
    built.value.width = parameters->width;
    built.value.height = parameters->height;
    built.value.video_delay = parameters->video_delay;
    built.value.extradata = parameters->extradata_size == 0
        ? NULL
        : parameters->extradata;
    built.value.extradata_size = (size_t)parameters->extradata_size;
    int result = vpff_map_field_order(stream->codecpar->field_order, &built.value.field_order);
    if (result >= 0) {
        result = vpff_map_track_extras(&built.extras, stream, parameters);
    }
    if (result < 0) {
        return result;
    }
    *track = built;
    return 0;
}

static int vpff_fill_audio_track(
    VPFFOwnedTrack *track,
    const AVStream *stream,
    const AVCodecParameters *parameters,
    AVRational time_base
) {
    if (track == NULL || stream == NULL || stream->codecpar == NULL ||
        !vpff_is_supported_audio(parameters) ||
        !vpff_time_base_is_valid(time_base) || stream->index < 0 ||
        parameters->sample_rate <= 0 || parameters->ch_layout.nb_channels <= 0 ||
        !vpff_parameters_are_bounded(parameters)) {
        return AVERROR_INVALIDDATA;
    }

    VPFFOwnedTrack built = {0};
    built.value.present = 1;
    built.value.stream_index = (int32_t)stream->index;
    built.value.codec = vpff_codec(parameters->codec_id);
    built.value.time_base_num = time_base.num;
    built.value.time_base_den = time_base.den;
    built.value.sample_rate = parameters->sample_rate;
    built.value.channel_count = parameters->ch_layout.nb_channels;
    if (parameters->ch_layout.order == AV_CHANNEL_ORDER_NATIVE) {
        built.value.channel_order = VPFF_CHANNEL_ORDER_NATIVE;
        built.value.has_channel_layout_mask = 1;
        built.value.channel_layout_mask = parameters->ch_layout.u.mask;
    } else {
        built.value.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED;
    }
    built.value.extradata = parameters->extradata_size == 0
        ? NULL
        : parameters->extradata;
    built.value.extradata_size = (size_t)parameters->extradata_size;
    int result = vpff_map_track_extras(&built.extras, stream, parameters);
    if (result < 0) {
        return result;
    }
    *track = built;
    return 0;
}

static int vpff_fill_borrowed_track_set(
    VPFFOwnedTrackSet *tracks,
    AVFormatContext *format,
    const VPFFSelection *selection,
    const VPFFVideoFilter *video_filter,
    const AVCodecParameters *audio_parameters,
    AVRational audio_time_base
) {
    if (tracks == NULL || format == NULL || selection == NULL) {
        return AVERROR_INVALIDDATA;
    }
    VPFFSelection refreshed = {0};
    int refresh_result = vpff_refresh_audio_primary_evidence(format, selection, &refreshed);
    if (refresh_result < 0) return refresh_result;
    VPFFOwnedTrackSet built = {0};
    built.has_program_id = refreshed.has_program_id ? 1 : 0;
    built.selected_program_id = refreshed.program_id;
    built.has_audio_primary_evidence = refreshed.has_audio_primary_evidence;
    built.audio_primary_evidence = refreshed.audio_primary_evidence;

    int result = 0;
    if (selection->video_stream_index >= 0) {
        if (video_filter == NULL || video_filter->context == NULL ||
            (unsigned int)selection->video_stream_index >= format->nb_streams) {
            result = AVERROR_INVALIDDATA;
        } else {
            AVStream *stream = format->streams[selection->video_stream_index];
            result = stream == NULL || stream->codecpar == NULL
                ? AVERROR_INVALIDDATA
                : vpff_fill_video_track(
                    &built.video,
                    stream,
                    video_filter->context->par_out,
                    video_filter->context->time_base_out,
                    vpff_guess_frame_rate(format, stream)
                );
        }
    }
    if (result >= 0 && selection->audio_stream_index >= 0) {
        if ((unsigned int)selection->audio_stream_index >= format->nb_streams) {
            result = AVERROR_INVALIDDATA;
        } else {
            AVStream *stream = format->streams[selection->audio_stream_index];
            result = stream == NULL || stream->codecpar == NULL
                ? AVERROR_INVALIDDATA
                : vpff_fill_audio_track(
                    &built.audio,
                    stream,
                    audio_parameters,
                    audio_time_base
                );
        }
    }
    if (result < 0) {
        return result;
    }
    *tracks = built;
    return 0;
}

static int vpff_make_track_set(
    VPFFOwnedTrackSet *tracks,
    AVFormatContext *format,
    const VPFFSelection *selection,
    const VPFFVideoFilter *video_filter,
    const AVCodecParameters *audio_parameters,
    AVRational audio_time_base
) {
    VPFFOwnedTrackSet borrowed = {0};
    int result = vpff_fill_borrowed_track_set(
        &borrowed,
        format,
        selection,
        video_filter,
        audio_parameters,
        audio_time_base
    );
    if (result < 0) {
        return result;
    }

    VPFFOwnedTrackSet built = {
        .has_program_id = borrowed.has_program_id,
        .selected_program_id = borrowed.selected_program_id,
        .has_audio_primary_evidence = borrowed.has_audio_primary_evidence,
        .audio_primary_evidence = borrowed.audio_primary_evidence,
    };
    if (borrowed.video.value.present) {
        result = vpff_copy_borrowed_track(&built.video, &borrowed.video);
    }
    if (result >= 0 && borrowed.audio.value.present) {
        result = vpff_copy_borrowed_track(&built.audio, &borrowed.audio);
    }
    if (result < 0) {
        vpff_owned_track_set_clear(&built);
        return result;
    }
    *tracks = built;
    return 0;
}

static bool vpff_rationals_equal(VPFFRational left, VPFFRational right) {
    if (left.num == right.num && left.den == right.den) {
        return true;
    }
    if (left.den <= 0 || right.den <= 0) {
        return false;
    }
    return av_cmp_q(
        (AVRational){left.num, left.den},
        (AVRational){right.num, right.den}
    ) == 0;
}

static bool vpff_track_extras_equal(
    const VPFFTrackExtrasV1 *left,
    const VPFFTrackExtrasV1 *right
) {
    return left->presence == right->presence &&
           left->dispositions == right->dispositions &&
           vpff_bytes_equal(
               left->language,
               left->language_size,
               right->language,
               right->language_size
           ) &&
           left->role == right->role &&
           left->service == right->service &&
           vpff_rationals_equal(
               left->sample_aspect_ratio,
               right->sample_aspect_ratio
           ) &&
           left->color_range == right->color_range &&
           left->color_primaries == right->color_primaries &&
           left->color_transfer == right->color_transfer &&
           left->color_matrix == right->color_matrix &&
           left->chroma_location == right->chroma_location &&
           vpff_rationals_equal(
               left->mastering_display_red_x,
               right->mastering_display_red_x
           ) &&
           vpff_rationals_equal(
               left->mastering_display_red_y,
               right->mastering_display_red_y
           ) &&
           vpff_rationals_equal(
               left->mastering_display_green_x,
               right->mastering_display_green_x
           ) &&
           vpff_rationals_equal(
               left->mastering_display_green_y,
               right->mastering_display_green_y
           ) &&
           vpff_rationals_equal(
               left->mastering_display_blue_x,
               right->mastering_display_blue_x
           ) &&
           vpff_rationals_equal(
               left->mastering_display_blue_y,
               right->mastering_display_blue_y
           ) &&
           vpff_rationals_equal(
               left->mastering_display_white_point_x,
               right->mastering_display_white_point_x
           ) &&
           vpff_rationals_equal(
               left->mastering_display_white_point_y,
               right->mastering_display_white_point_y
           ) &&
           vpff_rationals_equal(
               left->mastering_display_minimum_luminance,
               right->mastering_display_minimum_luminance
           ) &&
           vpff_rationals_equal(
               left->mastering_display_maximum_luminance,
               right->mastering_display_maximum_luminance
           ) &&
           left->maximum_content_light_level == right->maximum_content_light_level &&
           left->maximum_frame_average_light_level ==
               right->maximum_frame_average_light_level;
}

static bool vpff_public_tracks_equal(
    const VPFFOwnedTrack *left,
    const VPFFOwnedTrack *right
) {
    const VPFFTrack *a = &left->value;
    const VPFFTrack *b = &right->value;
    return a->present == b->present &&
           a->stream_index == b->stream_index &&
           a->codec == b->codec &&
           a->time_base_num == b->time_base_num &&
           a->time_base_den == b->time_base_den &&
           a->frame_rate_num == b->frame_rate_num &&
           a->frame_rate_den == b->frame_rate_den &&
           a->width == b->width &&
           a->height == b->height &&
           a->video_delay == b->video_delay &&
           a->field_order == b->field_order &&
           a->sample_rate == b->sample_rate &&
           a->channel_count == b->channel_count &&
           a->channel_order == b->channel_order &&
           a->has_channel_layout_mask == b->has_channel_layout_mask &&
           a->channel_layout_mask == b->channel_layout_mask &&
           vpff_bytes_equal(
               a->extradata,
               a->extradata_size,
               b->extradata,
               b->extradata_size
           ) &&
           vpff_track_extras_equal(&left->extras, &right->extras);
}

static bool vpff_track_sets_equal(
    const VPFFOwnedTrackSet *left,
    const VPFFOwnedTrackSet *right
) {
    return left->has_program_id == right->has_program_id &&
           left->selected_program_id == right->selected_program_id &&
           left->has_audio_primary_evidence == right->has_audio_primary_evidence &&
           memcmp(&left->audio_primary_evidence, &right->audio_primary_evidence,
                  sizeof(left->audio_primary_evidence)) == 0 &&
           vpff_public_tracks_equal(&left->video, &right->video) &&
           vpff_public_tracks_equal(&left->audio, &right->audio);
}

static void vpff_replace_track_set(
    VPFFOwnedTrackSet *destination,
    VPFFOwnedTrackSet *source
) {
    vpff_owned_track_set_clear(destination);
    *destination = *source;
    memset(source, 0, sizeof(*source));
}

static const AVPacketSideData *vpff_new_extradata(const AVPacket *packet) {
    return av_packet_side_data_get(
        packet->side_data,
        packet->side_data_elems,
        AV_PKT_DATA_NEW_EXTRADATA
    );
}

static int vpff_update_video_state(
    AVStream *stream,
    const AVPacketSideData *new_extradata,
    VPFFVideoFilter *filter,
    bool *changed,
    VPFFFailure *failure
) {
    if (!vpff_is_supported_video(stream->codecpar)) {
        failure->kind = VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR(ENOTSUP);
        return failure->code;
    }
    if (!vpff_time_base_is_valid(stream->time_base) ||
        !vpff_parameters_are_bounded(stream->codecpar) ||
        !vpff_side_data_is_valid(new_extradata)) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR_INVALIDDATA;
        return failure->code;
    }

    bool source_same = filter->source_key != NULL &&
                       vpff_parameters_equal_effective(
                           filter->source_key,
                           stream->codecpar,
                           NULL
                       );
    bool effective_same;
    if (new_extradata != NULL) {
        effective_same = vpff_parameters_equal_effective(
            filter->raw_key,
            stream->codecpar,
            new_extradata
        );
    } else if (source_same) {
        effective_same = filter->raw_key != NULL;
    } else {
        effective_same = vpff_parameters_equal_effective(
            filter->raw_key,
            stream->codecpar,
            NULL
        );
    }
    bool same = filter->context != NULL &&
                filter->context->time_base_in.num == stream->time_base.num &&
                filter->context->time_base_in.den == stream->time_base.den &&
                effective_same;
    if (same && source_same) {
        return 0;
    }

    if (same) {
        AVCodecParameters *source_replacement = NULL;
        int source_result = vpff_copy_effective_parameters(
            &source_replacement,
            stream->codecpar,
            NULL
        );
        if (source_result < 0) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_BSF_INIT;
            failure->code = source_result;
            return source_result;
        }
        avcodec_parameters_free(&filter->source_key);
        filter->source_key = source_replacement;
        return 0;
    }

    AVCodecParameters *effective = NULL;
    const AVCodecParameters *effective_base = new_extradata == NULL && source_same
        ? filter->raw_key
        : stream->codecpar;
    int result = vpff_copy_effective_parameters(
        &effective,
        effective_base,
        new_extradata
    );
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_BSF_INIT;
        failure->code = result;
        return result;
    }

    VPFFVideoFilter replacement = {0};
    result = vpff_video_filter_build(
        effective,
        stream->codecpar,
        stream->time_base,
        &replacement
    );
    avcodec_parameters_free(&effective);
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_BSF_INIT;
        failure->code = result;
        return result;
    }
    vpff_video_filter_free(filter);
    *filter = replacement;
    *changed = true;
    return 0;
}

static int vpff_update_audio_state(
    AVStream *stream,
    const AVPacketSideData *new_extradata,
    AVCodecParameters **audio_key,
    AVCodecParameters **audio_source_key,
    AVRational *audio_time_base,
    bool *changed,
    VPFFFailure *failure
) {
    if (!vpff_is_supported_audio_codec(stream->codecpar) ||
        !vpff_is_supported_audio_layout(stream->codecpar)) {
        failure->kind = VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR(ENOTSUP);
        return failure->code;
    }
    if (!vpff_time_base_is_valid(stream->time_base) || stream->codecpar->sample_rate <= 0 ||
        stream->codecpar->ch_layout.nb_channels <= 0 ||
        !vpff_parameters_are_bounded(stream->codecpar) ||
        !vpff_side_data_is_valid(new_extradata)) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR_INVALIDDATA;
        return failure->code;
    }

    bool source_same = *audio_source_key != NULL &&
                       vpff_parameters_equal_effective(
                           *audio_source_key,
                           stream->codecpar,
                           NULL
                       );
    bool effective_same;
    if (new_extradata != NULL) {
        effective_same = vpff_parameters_equal_effective(
            *audio_key,
            stream->codecpar,
            new_extradata
        );
    } else if (source_same) {
        effective_same = *audio_key != NULL;
    } else {
        effective_same = vpff_parameters_equal_effective(
            *audio_key,
            stream->codecpar,
            NULL
        );
    }
    bool same = *audio_key != NULL &&
                audio_time_base->num == stream->time_base.num &&
                audio_time_base->den == stream->time_base.den &&
                effective_same;
    if (same && source_same) {
        return 0;
    }

    if (same) {
        AVCodecParameters *source_replacement = NULL;
        int source_result = vpff_copy_effective_parameters(
            &source_replacement,
            stream->codecpar,
            NULL
        );
        if (source_result < 0) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_READ;
            failure->code = source_result;
            return source_result;
        }
        avcodec_parameters_free(audio_source_key);
        *audio_source_key = source_replacement;
        return 0;
    }

    AVCodecParameters *replacement = NULL;
    const AVCodecParameters *effective_base = new_extradata == NULL && source_same
        ? *audio_key
        : stream->codecpar;
    int result = vpff_copy_effective_parameters(
        &replacement,
        effective_base,
        new_extradata
    );
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = result;
        return result;
    }
    AVCodecParameters *source_replacement = NULL;
    result = vpff_copy_effective_parameters(
        &source_replacement,
        stream->codecpar,
        NULL
    );
    if (result < 0) {
        avcodec_parameters_free(&replacement);
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = result;
        return result;
    }
    avcodec_parameters_free(audio_key);
    *audio_key = replacement;
    avcodec_parameters_free(audio_source_key);
    *audio_source_key = source_replacement;
    *audio_time_base = stream->time_base;
    *changed = true;
    return 0;
}

static int vpff_update_selected_tracks(
    AVFormatContext *format,
    const VPFFSelection *selection,
    const AVPacket *packet,
    VPFFVideoFilter *video_filter,
    AVCodecParameters **audio_key,
    AVCodecParameters **audio_source_key,
    AVRational *audio_time_base,
    VPFFOwnedTrackSet *current_tracks,
    VPDemuxer *demuxer,
    VPFFFailure *failure
) {
    bool codec_parameters_changed = false;
    int result = 0;
    if (selection->video_stream_index >= 0) {
        AVStream *video_stream = format->streams[selection->video_stream_index];
        const AVPacketSideData *side_data =
            packet->stream_index == selection->video_stream_index
            ? vpff_new_extradata(packet)
            : NULL;
        result = vpff_update_video_state(
            video_stream,
            side_data,
            video_filter,
            &codec_parameters_changed,
            failure
        );
    }
    if (result >= 0 && selection->audio_stream_index >= 0) {
        AVStream *audio_stream = format->streams[selection->audio_stream_index];
        const AVPacketSideData *side_data =
            packet->stream_index == selection->audio_stream_index
            ? vpff_new_extradata(packet)
            : NULL;
        result = vpff_update_audio_state(
            audio_stream,
            side_data,
            audio_key,
            audio_source_key,
            audio_time_base,
            &codec_parameters_changed,
            failure
        );
    }
    if (result < 0) {
        return result;
    }
    if (vpff_is_cancelled(demuxer)) {
        return AVERROR_EXIT;
    }

    VPFFOwnedTrackSet borrowed = {0};
    result = vpff_fill_borrowed_track_set(
        &borrowed,
        format,
        selection,
        video_filter,
        *audio_key,
        *audio_time_base
    );
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = result;
        return result;
    }
    if (vpff_track_sets_equal(current_tracks, &borrowed)) {
        return 0;
    }

    VPFFOwnedTrackSet replacement = {0};
    result = vpff_make_track_set(
        &replacement,
        format,
        selection,
        video_filter,
        *audio_key,
        *audio_time_base
    );
    if (result < 0) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = result;
        return result;
    }
    if (!vpff_track_sets_equal(current_tracks, &replacement)) {
        if (vpff_is_cancelled(demuxer)) {
            vpff_owned_track_set_clear(&replacement);
            return AVERROR_EXIT;
        }
        vpff_replace_track_set(current_tracks, &replacement);
        vpff_emit_tracks(
            demuxer,
            VPFF_EVENT_DISCONTINUITY,
            VPFF_DISCONTINUITY_FORMAT_CHANGE,
            current_tracks
        );
        if (vpff_is_cancelled(demuxer)) {
            return AVERROR_EXIT;
        }
    }
    vpff_owned_track_set_clear(&replacement);
    return 0;
}

static int vpff_emit_packet(
    VPDemuxer *demuxer,
    const AVPacket *packet,
    int stream_index,
    VPFFCodec codec,
    AVRational time_base
) {
    if (vpff_is_cancelled(demuxer)) {
        return AVERROR_EXIT;
    }
    if (packet == NULL || packet->size < 0 ||
        (size_t)packet->size > VPFF_MAX_PACKET_BYTES ||
        (packet->size > 0 && packet->data == NULL) ||
        codec == VPFF_CODEC_UNSUPPORTED ||
        !vpff_time_base_is_valid(time_base)) {
        return AVERROR_INVALIDDATA;
    }

    VPFFDemuxEvent event = {0};
    event.kind = VPFF_EVENT_PACKET;
    event.packet.stream_index = (int32_t)stream_index;
    event.packet.codec = codec;
    event.packet.data = packet->size == 0 ? NULL : packet->data;
    event.packet.size = (size_t)packet->size;
    event.packet.pts = packet->pts;
    event.packet.dts = packet->dts;
    event.packet.duration = packet->duration;
    event.packet.time_base_num = time_base.num;
    event.packet.time_base_den = time_base.den;
    event.packet.is_key = (packet->flags & AV_PKT_FLAG_KEY) != 0;
    event.packet.is_corrupt = (packet->flags & AV_PKT_FLAG_CORRUPT) != 0;
    vpff_emit_event(demuxer, &event, NULL);
    return vpff_is_cancelled(demuxer) ? AVERROR_EXIT : 0;
}

static int vpff_drain_video_filter(
    VPDemuxer *demuxer,
    VPFFVideoFilter *filter,
    int stream_index,
    AVPacket *output,
    VPFFFailure *failure
) {
    for (;;) {
        int result = av_bsf_receive_packet(filter->context, output);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return result;
        }
        if (result < 0) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_BSF_RECEIVE;
            failure->code = result;
            return result;
        }
        result = vpff_emit_packet(
            demuxer,
            output,
            stream_index,
            vpff_codec(filter->context->par_out->codec_id),
            filter->context->time_base_out
        );
        av_packet_unref(output);
        if (result < 0) {
            if (!vpff_is_cancelled(demuxer)) {
                failure->kind = VPFF_DEMUX_ERROR_READ;
                failure->stage = VPFF_DEMUX_STAGE_BSF_RECEIVE;
                failure->code = result;
            }
            return result;
        }
    }
}

static int vpff_send_video_packet(
    VPDemuxer *demuxer,
    VPFFVideoFilter *filter,
    int stream_index,
    AVPacket *input,
    AVPacket *output,
    VPFFFailure *failure
) {
    for (;;) {
        int result = av_bsf_send_packet(filter->context, input);
        if (result == AVERROR(EAGAIN)) {
            result = vpff_drain_video_filter(
                demuxer,
                filter,
                stream_index,
                output,
                failure
            );
            if (result == AVERROR(EAGAIN)) {
                continue;
            }
            if (result == AVERROR_EOF) {
                failure->kind = VPFF_DEMUX_ERROR_READ;
                failure->stage = VPFF_DEMUX_STAGE_BSF_SEND;
                failure->code = AVERROR_EOF;
                return AVERROR_EOF;
            }
            return result;
        }
        if (result < 0) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_BSF_SEND;
            failure->code = result;
            return result;
        }
        int drain_result = vpff_drain_video_filter(
            demuxer,
            filter,
            stream_index,
            output,
            failure
        );
        return drain_result == AVERROR(EAGAIN) || drain_result == AVERROR_EOF
            ? 0
            : drain_result;
    }
}

static int vpff_flush_video_filter(
    VPDemuxer *demuxer,
    VPFFVideoFilter *filter,
    int stream_index,
    AVPacket *output,
    VPFFFailure *failure
) {
    for (;;) {
        int result = av_bsf_send_packet(filter->context, NULL);
        if (result == AVERROR(EAGAIN)) {
            result = vpff_drain_video_filter(
                demuxer,
                filter,
                stream_index,
                output,
                failure
            );
            if (result == AVERROR(EAGAIN)) {
                continue;
            }
            if (result == AVERROR_EOF) {
                return 0;
            }
            return result;
        }
        if (result < 0 && result != AVERROR_EOF) {
            failure->kind = VPFF_DEMUX_ERROR_READ;
            failure->stage = VPFF_DEMUX_STAGE_BSF_SEND;
            failure->code = result;
            return result;
        }
        break;
    }

    int result = vpff_drain_video_filter(
        demuxer,
        filter,
        stream_index,
        output,
        failure
    );
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int vpff_process_selected_packet(
    AVFormatContext *format,
    const VPFFSelection *selection,
    AVPacket *input,
    AVPacket *output,
    VPFFVideoFilter *video_filter,
    AVCodecParameters **audio_key,
    AVCodecParameters **audio_source_key,
    AVRational *audio_time_base,
    VPFFOwnedTrackSet *current_tracks,
    VPDemuxer *demuxer,
    VPFFFailure *failure
) {
    if (format == NULL || selection == NULL || input == NULL || output == NULL ||
        input->stream_index < 0 ||
        (unsigned int)input->stream_index >= format->nb_streams ||
        (input->stream_index != selection->video_stream_index &&
         input->stream_index != selection->audio_stream_index) ||
        !vpff_packet_is_bounded(input)) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR_INVALIDDATA;
        return failure->code;
    }

    AVStream *packet_stream = format->streams[input->stream_index];
    if (packet_stream == NULL || packet_stream->codecpar == NULL ||
        packet_stream->index != input->stream_index) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = AVERROR_INVALIDDATA;
        return failure->code;
    }

    int result = vpff_update_selected_tracks(
        format,
        selection,
        input,
        video_filter,
        audio_key,
        audio_source_key,
        audio_time_base,
        current_tracks,
        demuxer,
        failure
    );
    if (result < 0) {
        return result;
    }

    if (input->stream_index == selection->video_stream_index &&
        input->data == NULL && input->side_data_elems == 0) {
        return 0;
    }
    if (input->stream_index == selection->video_stream_index) {
        return vpff_send_video_packet(
            demuxer,
            video_filter,
            selection->video_stream_index,
            input,
            output,
            failure
        );
    }

    result = vpff_emit_packet(
        demuxer,
        input,
        selection->audio_stream_index,
        vpff_codec((*audio_key)->codec_id),
        *audio_time_base
    );
    if (result < 0 && !vpff_is_cancelled(demuxer)) {
        failure->kind = VPFF_DEMUX_ERROR_READ;
        failure->stage = VPFF_DEMUX_STAGE_READ;
        failure->code = result;
    }
    return result;
}

typedef struct {
    AVPacket *output;
    VPFFVideoFilter *video_filter;
    AVCodecParameters **audio_key;
    AVCodecParameters **audio_source_key;
    AVRational *audio_time_base;
    VPFFOwnedTrackSet *current_tracks;
    VPDemuxer *demuxer;
    VPFFFailure *failure;
} VPFFBootstrapLiveReplay;

static int vpff_video_bootstrap_replay_live(
    void *context,
    AVFormatContext *format,
    const VPFFSelection *selection,
    AVPacket *packet
) {
    VPFFBootstrapLiveReplay *replay = context;
    if (replay == NULL) {
        return AVERROR_INVALIDDATA;
    }
    return vpff_process_selected_packet(
        format,
        selection,
        packet,
        replay->output,
        replay->video_filter,
        replay->audio_key,
        replay->audio_source_key,
        replay->audio_time_base,
        replay->current_tracks,
        replay->demuxer,
        replay->failure
    );
}

static int vpff_set_open_options(
    AVDictionary **options,
    int64_t timeout_us
) {
    int result = av_dict_set_int(options, "rw_timeout", timeout_us, 0);
    if (result >= 0) {
        result = av_dict_set_int(options, "timeout", timeout_us, 0);
    }
    if (result >= 0) {
        result = av_dict_set(
            options,
            "protocol_whitelist",
            VPFF_PROTOCOL_WHITELIST,
            0
        );
    }
    if (result >= 0) {
        // Keep one complete segment between playback and the live edge. Starting
        // at -1 gives FFmpeg exactly one target-duration segment to consume while
        // its HLS demuxer waits that same target duration before the next playlist
        // reload; any network or scheduling overhead therefore creates a gap at
        // every segment boundary. The pipeline now retains multi-segment audio
        // and compressed-video reservoirs, so -2 adds the needed safety margin
        // without paying FFmpeg's default three-segment live latency.
        // HLS consumes this private option; other demuxers leave it for the exact
        // cleanup below.
        result = av_dict_set_int(options, "live_start_index", -2, 0);
    }
    return result;
}

static void vpff_choose_terminal(
    VPDemuxer *demuxer,
    const VPFFFailure *failure,
    VPFFDemuxEventKind *terminal_kind,
    VPFFDemuxErrorKind *error_kind,
    VPFFDemuxErrorStage *error_stage,
    int *error_code
) {
    if (vpff_is_cancelled(demuxer)) {
        *terminal_kind = VPFF_EVENT_CANCELLED;
        *error_kind = VPFF_DEMUX_ERROR_NONE;
        *error_stage = VPFF_DEMUX_STAGE_NONE;
        *error_code = 0;
    } else if (vpff_deadline_expired(demuxer) ||
               failure->code == AVERROR(ETIMEDOUT)) {
        *terminal_kind = VPFF_EVENT_ERROR;
        *error_kind = VPFF_DEMUX_ERROR_TIMEOUT;
        *error_stage = failure->stage;
        *error_code = failure->code < 0 ? failure->code : AVERROR(ETIMEDOUT);
    } else {
        *terminal_kind = VPFF_EVENT_ERROR;
        *error_kind = failure->kind;
        *error_stage = failure->stage;
        *error_code = failure->code < 0 ? failure->code : AVERROR(EIO);
    }
}

static int32_t vpff_demuxer_create_common(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallback callback,
    VPFFDemuxCallbackV2 callback_v2,
    void *context,
    VPDemuxer **out_demuxer
) {
    if (out_demuxer == NULL) {
        return -EINVAL;
    }
    *out_demuxer = NULL;
    if (url_bytes == NULL || url_size == 0 || url_size > VPFF_MAX_URL_BYTES ||
        timeout_us <= 0 || (callback == NULL) == (callback_v2 == NULL) ||
        memchr(url_bytes, 0, url_size) != NULL ||
        !vpff_utf8_is_valid(url_bytes, url_size) ||
        !vpff_has_http_scheme(url_bytes, url_size) || url_size == SIZE_MAX) {
        return -EINVAL;
    }

    VPDemuxer *demuxer = calloc(1, sizeof(*demuxer));
    if (demuxer == NULL) {
        return -ENOMEM;
    }
    demuxer->url = malloc(url_size + 1);
    if (demuxer->url == NULL) {
        free(demuxer);
        return -ENOMEM;
    }
    memcpy(demuxer->url, url_bytes, url_size);
    demuxer->url[url_size] = '\0';
    if (!vpff_normalize_direct_child_scheme(demuxer->url, url_size)) {
        free(demuxer->url);
        free(demuxer);
        return -EINVAL;
    }
    demuxer->timeout_us = timeout_us;
    demuxer->callback = callback;
    demuxer->callback_v2 = callback_v2;
    demuxer->context = context;
    atomic_init(&demuxer->cancelled, false);
    atomic_init(&demuxer->run_claimed, false);
    atomic_init(&demuxer->deadline_us, 0);
    *out_demuxer = demuxer;
    return 0;
}

int32_t vp_ffmpeg_demuxer_create(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallback callback,
    void *context,
    VPDemuxer **out_demuxer
) {
    return vpff_demuxer_create_common(
        url_bytes,
        url_size,
        timeout_us,
        callback,
        NULL,
        context,
        out_demuxer
    );
}

int32_t vp_ffmpeg_demuxer_create_v2(
    const uint8_t *url_bytes,
    size_t url_size,
    int64_t timeout_us,
    VPFFDemuxCallbackV2 callback,
    void *context,
    VPDemuxer **out_demuxer
) {
    return vpff_demuxer_create_common(
        url_bytes,
        url_size,
        timeout_us,
        NULL,
        callback,
        context,
        out_demuxer
    );
}

int32_t vp_ffmpeg_demuxer_run(VPDemuxer *demuxer) {
    if (demuxer == NULL || atomic_exchange_explicit(
            &demuxer->run_claimed,
            true,
            memory_order_acq_rel
        )) {
        return -EINVAL;
    }
    if (vpff_is_cancelled(demuxer)) {
        vpff_emit_terminal(
            demuxer,
            VPFF_EVENT_CANCELLED,
            VPFF_DEMUX_ERROR_NONE,
            VPFF_DEMUX_STAGE_NONE,
            0
        );
        return 0;
    }

    int once_result = pthread_once(&vpff_log_install_once, vpff_install_silent_logging);
    if (once_result != 0) {
        int error_code = once_result > 0 ? -once_result : -EIO;
        vpff_emit_terminal(
            demuxer,
            VPFF_EVENT_ERROR,
            VPFF_DEMUX_ERROR_OPEN,
            VPFF_DEMUX_STAGE_VALIDATION,
            error_code
        );
        return (int32_t)error_code;
    }

    AVFormatContext *format = NULL;
    AVDictionary *options = NULL;
    AVPacket *input = NULL;
    AVPacket *output = NULL;
    VPFFVideoBootstrap video_bootstrap = {0};
    VPFFVideoFilter video_filter = {0};
    AVCodecParameters *audio_key = NULL;
    AVCodecParameters *audio_source_key = NULL;
    AVRational audio_time_base = {0, 1};
    VPFFOwnedTrackSet current_tracks = {0};
    VPFFSelection selection = {
        .video_stream_index = -1,
        .audio_stream_index = -1,
    };
    VPFFFailure failure = {
        .kind = VPFF_DEMUX_ERROR_OPEN,
        .stage = VPFF_DEMUX_STAGE_OPEN,
        .code = AVERROR(EIO),
    };
    VPFFDemuxEventKind terminal_kind = VPFF_EVENT_ERROR;
    VPFFDemuxErrorKind terminal_error_kind = VPFF_DEMUX_ERROR_OPEN;
    VPFFDemuxErrorStage terminal_error_stage = VPFF_DEMUX_STAGE_OPEN;
    int terminal_error_code = AVERROR(EIO);
    int result = 0;

    format = avformat_alloc_context();
    if (format == NULL) {
        result = AVERROR(ENOMEM);
        failure.code = result;
        goto finish_failure;
    }
    format->opaque = demuxer;
    format->interrupt_callback.callback = vpff_interrupt;
    format->interrupt_callback.opaque = demuxer;
    format->io_open = vpff_io_open;

    result = vpff_set_open_options(&options, demuxer->timeout_us);
    if (result < 0) {
        failure.code = result;
        goto finish_failure;
    }
    vpff_refresh_deadline(demuxer);
    result = avformat_open_input(&format, demuxer->url, NULL, &options);
    if (result < 0) {
        failure.code = result;
        goto finish_failure;
    }
    vpff_clear_deadline(demuxer);
    if (vpff_is_cancelled(demuxer)) {
        failure.code = AVERROR_EXIT;
        goto finish_failure;
    }
    // `live_start_index` is deliberately offered to every input so FFmpeg, not
    // a URL suffix heuristic, decides whether the source is HLS. HLS must
    // consume it; every other demuxer must leave our private option untouched
    // so it can be removed without weakening the remaining-option audit.
    AVDictionaryEntry *live_start_option = av_dict_get(
        options,
        "live_start_index",
        NULL,
        0
    );
    bool is_hls = format->iformat != NULL &&
                  strcmp(format->iformat->name, "hls") == 0;
    if (is_hls == (live_start_option != NULL)) {
        result = AVERROR_OPTION_NOT_FOUND;
        failure.code = result;
        goto finish_failure;
    }
    if (!is_hls) {
        result = av_dict_set(&options, "live_start_index", NULL, 0);
        if (result < 0) {
            failure.code = result;
            goto finish_failure;
        }
    }
    if (av_dict_count(options) != 0) {
        result = AVERROR_OPTION_NOT_FOUND;
        failure.code = result;
        goto finish_failure;
    }
    av_dict_free(&options);

    failure.stage = VPFF_DEMUX_STAGE_STREAM_INFO;
    vpff_refresh_deadline(demuxer);
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        failure.code = result;
        goto finish_failure;
    }
    vpff_clear_deadline(demuxer);
    if (vpff_is_cancelled(demuxer)) {
        failure.code = AVERROR_EXIT;
        goto finish_failure;
    }

    failure.kind = VPFF_DEMUX_ERROR_READ;
    failure.stage = VPFF_DEMUX_STAGE_SELECTION;
    result = vpff_select_streams(format, &selection, &failure);
    if (result < 0) {
        goto finish_failure;
    }
    if (vpff_is_cancelled(demuxer)) {
        failure.code = AVERROR_EXIT;
        goto finish_failure;
    }

    input = av_packet_alloc();
    output = av_packet_alloc();
    if (input == NULL || output == NULL) {
        result = AVERROR(ENOMEM);
        failure.stage = VPFF_DEMUX_STAGE_READ;
        failure.code = result;
        goto finish_failure;
    }

    if (selection.video_stream_index >= 0) {
        AVStream *video_stream = format->streams[selection.video_stream_index];
        if (!vpff_video_dimensions_are_complete(video_stream->codecpar)) {
            failure.kind = VPFF_DEMUX_ERROR_READ;
            failure.stage = VPFF_DEMUX_STAGE_SELECTION;
            result = vpff_video_bootstrap_initialize(
                &video_bootstrap,
                format,
                &selection
            );
            if (result < 0) {
                failure.code = result;
                goto finish_failure;
            }
            VPFFBootstrapLiveReader reader = {
                .format = format,
                .demuxer = demuxer,
            };
            result = vpff_video_bootstrap_collect(
                &video_bootstrap,
                format,
                &selection,
                input,
                vpff_video_bootstrap_read_live,
                &reader,
                vpff_video_bootstrap_parse_ffmpeg,
                &video_bootstrap
            );
            if (result < 0) {
                failure.stage = VPFF_DEMUX_STAGE_READ;
                failure.code = result;
                goto finish_failure;
            }
            result = vpff_video_bootstrap_restore_initial(
                &video_bootstrap,
                format,
                &selection
            );
            if (result < 0) {
                failure.code = result;
                goto finish_failure;
            }
        }
    }

    if (selection.video_stream_index >= 0) {
        bool changed = false;
        result = vpff_update_video_state(
            format->streams[selection.video_stream_index],
            NULL,
            &video_filter,
            &changed,
            &failure
        );
        if (result < 0) {
            if (failure.stage == VPFF_DEMUX_STAGE_READ) {
                failure.stage = VPFF_DEMUX_STAGE_SELECTION;
            }
            goto finish_failure;
        }
    }
    if (selection.audio_stream_index >= 0) {
        bool changed = false;
        result = vpff_update_audio_state(
            format->streams[selection.audio_stream_index],
            NULL,
            &audio_key,
            &audio_source_key,
            &audio_time_base,
            &changed,
            &failure
        );
        if (result < 0) {
            if (failure.stage == VPFF_DEMUX_STAGE_READ) {
                failure.stage = VPFF_DEMUX_STAGE_SELECTION;
            }
            goto finish_failure;
        }
    }

    result = vpff_make_track_set(
        &current_tracks,
        format,
        &selection,
        &video_filter,
        audio_key,
        audio_time_base
    );
    if (result < 0) {
        failure.kind = VPFF_DEMUX_ERROR_READ;
        failure.stage = selection.video_stream_index >= 0
            ? VPFF_DEMUX_STAGE_BSF_INIT
            : VPFF_DEMUX_STAGE_SELECTION;
        failure.code = result;
        goto finish_failure;
    }

    if (vpff_is_cancelled(demuxer)) {
        result = AVERROR_EXIT;
        failure.stage = VPFF_DEMUX_STAGE_READ;
        failure.code = result;
        goto finish_failure;
    }
    vpff_emit_tracks(
        demuxer,
        VPFF_EVENT_TRACKS,
        VPFF_DISCONTINUITY_NONE,
        &current_tracks
    );
    if (vpff_is_cancelled(demuxer)) {
        result = AVERROR_EXIT;
        failure.stage = VPFF_DEMUX_STAGE_READ;
        failure.code = result;
        goto finish_failure;
    }

    if (video_bootstrap.packet_count > 0) {
        VPFFBootstrapLiveReplay replay = {
            .output = output,
            .video_filter = &video_filter,
            .audio_key = &audio_key,
            .audio_source_key = &audio_source_key,
            .audio_time_base = &audio_time_base,
            .current_tracks = &current_tracks,
            .demuxer = demuxer,
            .failure = &failure,
        };
        result = vpff_video_bootstrap_replay(
            &video_bootstrap,
            format,
            &selection,
            vpff_video_bootstrap_replay_live,
            &replay
        );
        if (result < 0) {
            goto finish_failure;
        }
    }

    for (;;) {
        failure.kind = VPFF_DEMUX_ERROR_READ;
        failure.stage = VPFF_DEMUX_STAGE_READ;
        vpff_refresh_deadline(demuxer);
        do {
            result = av_read_frame(format, input);
            if (result == AVERROR(EAGAIN) && !vpff_interrupt(demuxer)) {
                av_usleep(1000);
            }
        } while (result == AVERROR(EAGAIN) && !vpff_interrupt(demuxer));

        if (result == AVERROR_EOF) {
            vpff_clear_deadline(demuxer);
            if (vpff_is_cancelled(demuxer)) {
                failure.code = AVERROR_EXIT;
                goto finish_failure;
            }
            if (selection.video_stream_index >= 0) {
                result = vpff_flush_video_filter(
                    demuxer,
                    &video_filter,
                    selection.video_stream_index,
                    output,
                    &failure
                );
                if (result < 0) {
                    goto finish_failure;
                }
            }
            terminal_kind = VPFF_EVENT_END;
            terminal_error_kind = VPFF_DEMUX_ERROR_NONE;
            terminal_error_stage = VPFF_DEMUX_STAGE_NONE;
            terminal_error_code = 0;
            result = 0;
            goto finish;
        }
        if (result < 0) {
            failure.code = result;
            goto finish_failure;
        }
        vpff_clear_deadline(demuxer);

        if (vpff_is_cancelled(demuxer)) {
            failure.code = AVERROR_EXIT;
            goto finish_failure;
        }
        if (input->stream_index < 0 ||
            (unsigned int)input->stream_index >= format->nb_streams) {
            failure.code = AVERROR_INVALIDDATA;
            goto finish_failure;
        }
        AVStream *packet_stream = format->streams[input->stream_index];
        if (packet_stream == NULL || packet_stream->codecpar == NULL ||
            packet_stream->index != input->stream_index) {
            failure.code = AVERROR_INVALIDDATA;
            goto finish_failure;
        }
        if (input->stream_index != selection.video_stream_index &&
            input->stream_index != selection.audio_stream_index) {
            if (input->stream_index >= 0 &&
                (unsigned int)input->stream_index < format->nb_streams) {
                packet_stream->discard = AVDISCARD_ALL;
            }
            av_packet_unref(input);
            continue;
        }
        result = vpff_process_selected_packet(
            format,
            &selection,
            input,
            output,
            &video_filter,
            &audio_key,
            &audio_source_key,
            &audio_time_base,
            &current_tracks,
            demuxer,
            &failure
        );
        av_packet_unref(input);
        if (result < 0) {
            goto finish_failure;
        }
    }

finish_failure:
    vpff_choose_terminal(
        demuxer,
        &failure,
        &terminal_kind,
        &terminal_error_kind,
        &terminal_error_stage,
        &terminal_error_code
    );
    result = terminal_kind == VPFF_EVENT_CANCELLED ? 0 : terminal_error_code;

finish:
    av_dict_free(&options);
    av_packet_free(&input);
    av_packet_free(&output);
    (void)vpff_video_bootstrap_clear(&video_bootstrap);
    vpff_video_filter_free(&video_filter);
    avcodec_parameters_free(&audio_key);
    avcodec_parameters_free(&audio_source_key);
    avformat_close_input(&format);
    vpff_owned_track_set_clear(&current_tracks);
    vpff_clear_deadline(demuxer);
    if (terminal_kind != VPFF_EVENT_CANCELLED && vpff_is_cancelled(demuxer)) {
        terminal_kind = VPFF_EVENT_CANCELLED;
        terminal_error_kind = VPFF_DEMUX_ERROR_NONE;
        terminal_error_stage = VPFF_DEMUX_STAGE_NONE;
        terminal_error_code = 0;
        result = 0;
    }
    vpff_emit_terminal(
        demuxer,
        terminal_kind,
        terminal_error_kind,
        terminal_error_stage,
        terminal_error_code
    );
    return (int32_t)result;
}

void vp_ffmpeg_demuxer_cancel(VPDemuxer *demuxer) {
    if (demuxer != NULL) {
        atomic_store_explicit(&demuxer->cancelled, true, memory_order_release);
    }
}

void vp_ffmpeg_demuxer_destroy(VPDemuxer *demuxer) {
    if (demuxer == NULL) {
        return;
    }
    free(demuxer->url);
    free(demuxer);
}

#if DEBUG
typedef struct {
    VPFFBootstrapDebugScenario scenario;
    VPFFBootstrapDebugResult *result;
    const uint8_t *first_input;
    int64_t first_position;
    uint8_t output;
} VPFFBootstrapDebugParser;

typedef struct {
    VPFFBootstrapDebugResult *result;
} VPFFBootstrapDebugReplay;

static AVFormatContext *vpff_bootstrap_debug_format(void) {
    AVFormatContext *format = avformat_alloc_context();
    if (format == NULL) {
        return NULL;
    }
    AVStream *video = avformat_new_stream(format, NULL);
    AVStream *audio = avformat_new_stream(format, NULL);
    if (video == NULL || audio == NULL) {
        avformat_free_context(format);
        return NULL;
    }
    video->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
    video->codecpar->codec_id = AV_CODEC_ID_H264;
    video->codecpar->video_delay = 0;
    video->time_base = (AVRational){1, 90000};

    audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    audio->codecpar->codec_id = AV_CODEC_ID_AAC;
    audio->codecpar->sample_rate = 48000;
    audio->time_base = (AVRational){1, 48000};
    if (av_channel_layout_from_mask(
            &audio->codecpar->ch_layout,
            AV_CH_LAYOUT_STEREO
        ) < 0) {
        avformat_free_context(format);
        return NULL;
    }
    return format;
}

static AVPacket *vpff_bootstrap_debug_packet(int stream_index) {
    AVPacket *packet = av_packet_alloc();
    if (packet == NULL || av_new_packet(packet, 1) < 0) {
        av_packet_free(&packet);
        return NULL;
    }
    packet->data[0] = 0;
    packet->stream_index = stream_index;
    packet->pts = 0;
    packet->dts = 0;
    packet->pos = 0;
    return packet;
}

static int vpff_bootstrap_debug_eof_read(void *context, AVPacket *packet) {
    (void)context;
    (void)packet;
    return AVERROR_EOF;
}

static int vpff_bootstrap_debug_parse(
    void *context,
    const uint8_t *data,
    int size,
    int64_t pts,
    int64_t dts,
    int64_t position,
    VPFFBootstrapParserStep *step
) {
    (void)pts;
    (void)dts;
    VPFFBootstrapDebugParser *parser = context;
    if (parser == NULL || parser->result == NULL || data == NULL ||
        size <= 0 || step == NULL) {
        return AVERROR_INVALIDDATA;
    }
    if (parser->result->parser_call_count == 0) {
        parser->first_input = data;
        parser->first_position = position;
    } else if (parser->first_input == data && parser->first_position == position) {
        parser->result->retried_same_input = 1;
    }
    parser->result->parser_call_count += 1;

    switch (parser->scenario) {
    case VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_NO_OUTPUT:
        return 0;
    case VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_WITH_OUTPUT:
        if (parser->result->parser_call_count == 1) {
            step->output = &parser->output;
            step->output_size = 1;
            return 0;
        }
        step->consumed = size;
        step->width = 1280;
        step->height = 720;
        step->coded_width = 1280;
        step->coded_height = 720;
        return 0;
    case VPFF_BOOTSTRAP_DEBUG_REPEATED_ZERO_CONSUMED:
        step->output = &parser->output;
        step->output_size = 1;
        return 0;
    default:
        return AVERROR(EINVAL);
    }
}

static int vpff_bootstrap_debug_replay(
    void *context,
    AVFormatContext *format,
    const VPFFSelection *selection,
    AVPacket *packet
) {
    VPFFBootstrapDebugReplay *replay = context;
    if (replay == NULL || replay->result == NULL || format == NULL ||
        selection == NULL || packet == NULL) {
        return AVERROR_INVALIDDATA;
    }
    VPFFBootstrapDebugResult *result = replay->result;
    size_t replay_index = result->replayed_packet_count;
    AVStream *stream = format->streams[packet->stream_index];
    if (replay_index == 0 && packet->stream_index == selection->video_stream_index) {
        result->first_replay_width = stream->codecpar->width;
        result->first_replay_time_base_num = stream->time_base.num;
        result->first_replay_time_base_den = stream->time_base.den;
    } else if (replay_index == 1 &&
               packet->stream_index == selection->audio_stream_index) {
        result->second_replay_sample_rate = stream->codecpar->sample_rate;
        result->second_replay_time_base_num = stream->time_base.num;
        result->second_replay_time_base_den = stream->time_base.den;
    } else if (replay_index == 2 &&
               packet->stream_index == selection->video_stream_index) {
        result->third_replay_width = stream->codecpar->width;
        result->third_replay_height = stream->codecpar->height;
        result->third_replay_time_base_num = stream->time_base.num;
        result->third_replay_time_base_den = stream->time_base.den;
    } else {
        return AVERROR_INVALIDDATA;
    }
    result->replayed_packet_count += 1;
    return 0;
}

int32_t vp_ffmpeg_demuxer_debug_run_bootstrap(
    VPFFBootstrapDebugScenario scenario,
    VPFFBootstrapDebugResult *out_result
) {
    if (out_result == NULL) {
        return AVERROR(EINVAL);
    }
    memset(out_result, 0, sizeof(*out_result));

    AVFormatContext *format = vpff_bootstrap_debug_format();
    AVPacket *packet = vpff_bootstrap_debug_packet(0);
    AVPacket *input = av_packet_alloc();
    VPFFVideoBootstrap bootstrap = {0};
    VPFFSelection selection = {
        .video_stream_index = 0,
        .audio_stream_index = 1,
    };
    int result = format == NULL || packet == NULL || input == NULL
        ? AVERROR(ENOMEM)
        : vpff_video_bootstrap_initialize(&bootstrap, format, &selection);
    if (result < 0) {
        goto finish;
    }

    if (scenario == VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_EXACT ||
        scenario == VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_OVERFLOW) {
        size_t requested = scenario == VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_EXACT
            ? VPFF_BOOTSTRAP_MAX_PACKETS
            : VPFF_BOOTSTRAP_MAX_PACKETS + 1;
        for (size_t index = 0; index < requested; index += 1) {
            result = vpff_video_bootstrap_retain_with_footprint(
                &bootstrap,
                packet,
                format->streams[0],
                0
            );
            if (result < 0) {
                break;
            }
            out_result->peak_packet_count = bootstrap.packet_count;
            out_result->peak_accounted_bytes = bootstrap.total_bytes;
        }
    } else if (scenario == VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_EXACT ||
               scenario == VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_OVERFLOW) {
        size_t parameter_bytes = 0;
        result = vpff_parameter_footprint(
            format->streams[0]->codecpar,
            &parameter_bytes
        );
        if (result >= 0 &&
            bootstrap.total_bytes + parameter_bytes <= VPFF_BOOTSTRAP_MAX_BYTES) {
            size_t packet_bytes = VPFF_BOOTSTRAP_MAX_BYTES -
                bootstrap.total_bytes - parameter_bytes;
            if (scenario == VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_OVERFLOW) {
                packet_bytes += 1;
            }
            result = vpff_video_bootstrap_retain_with_footprint(
                &bootstrap,
                packet,
                format->streams[0],
                packet_bytes
            );
            out_result->peak_packet_count = bootstrap.packet_count;
            out_result->peak_accounted_bytes = bootstrap.total_bytes;
        }
    } else if (scenario == VPFF_BOOTSTRAP_DEBUG_EOF_BEFORE_DIMENSIONS) {
        result = vpff_video_bootstrap_collect(
            &bootstrap,
            format,
            &selection,
            input,
            vpff_bootstrap_debug_eof_read,
            NULL,
            vpff_video_bootstrap_parse_ffmpeg,
            &bootstrap
        );
    } else if (scenario == VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_NO_OUTPUT ||
               scenario == VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_WITH_OUTPUT ||
               scenario == VPFF_BOOTSTRAP_DEBUG_REPEATED_ZERO_CONSUMED) {
        VPFFBootstrapDebugParser parser = {
            .scenario = scenario,
            .result = out_result,
        };
        bool complete = false;
        result = vpff_video_bootstrap_parse(
            &bootstrap,
            packet,
            vpff_bootstrap_debug_parse,
            &parser,
            &complete
        );
        if (result >= 0 && !complete) {
            result = AVERROR_INVALIDDATA;
        }
    } else if (scenario == VPFF_BOOTSTRAP_DEBUG_SNAPSHOT_REPLAY) {
        bootstrap.parsed_width = 1280;
        bootstrap.parsed_height = 720;
        result = vpff_video_bootstrap_retain(
            &bootstrap,
            packet,
            format->streams[0]
        );
        if (result >= 0) {
            packet->stream_index = 1;
            result = vpff_video_bootstrap_retain(
                &bootstrap,
                packet,
                format->streams[1]
            );
        }
        if (result >= 0) {
            format->streams[0]->codecpar->width = 1920;
            format->streams[0]->codecpar->height = 1080;
            format->streams[0]->time_base = (AVRational){1, 45000};
            packet->stream_index = 0;
            result = vpff_video_bootstrap_retain(
                &bootstrap,
                packet,
                format->streams[0]
            );
        }
        out_result->peak_packet_count = bootstrap.packet_count;
        out_result->peak_accounted_bytes = bootstrap.total_bytes;
        if (result >= 0) {
            result = vpff_video_bootstrap_restore_initial(
                &bootstrap,
                format,
                &selection
            );
        }
        if (result >= 0) {
            out_result->initial_width = format->streams[0]->codecpar->width;
            out_result->initial_height = format->streams[0]->codecpar->height;
            VPFFBootstrapDebugReplay replay = {.result = out_result};
            result = vpff_video_bootstrap_replay(
                &bootstrap,
                format,
                &selection,
                vpff_bootstrap_debug_replay,
                &replay
            );
        }
    } else {
        result = AVERROR(EINVAL);
    }

finish:
    out_result->live_resource_count = vpff_video_bootstrap_clear(&bootstrap);
    av_packet_free(&packet);
    av_packet_free(&input);
    avformat_free_context(format);
    return (int32_t)result;
}

static int vpff_debug_add_side_data(
    AVCodecParameters *parameters,
    enum AVPacketSideDataType type,
    const void *value,
    size_t size
) {
    AVPacketSideData *side_data = av_packet_side_data_new(
        &parameters->coded_side_data,
        &parameters->nb_coded_side_data,
        type,
        size,
        0
    );
    if (side_data == NULL) {
        return AVERROR(ENOMEM);
    }
    memcpy(side_data->data, value, size);
    return 0;
}

static int vpff_debug_configure_full_track_evidence(AVFormatContext *format) {
    AVStream *video = format->streams[0];
    AVStream *audio = format->streams[1];
    int result = av_dict_set(&video->metadata, "language", "zh-Hant", 0);
    if (result >= 0) {
        result = av_dict_set(&video->metadata, "role", "main", 0);
    }
    if (result >= 0) {
        result = av_dict_set(
            &video->metadata,
            "service",
            "independent-main",
            0
        );
    }
    if (result >= 0) {
        result = av_dict_set(&audio->metadata, "language", "en", 0);
    }
    if (result >= 0) {
        result = av_dict_set(&audio->metadata, "service", "associated", 0);
    }
    if (result < 0) {
        return result;
    }

    video->disposition = AV_DISPOSITION_DEFAULT | AV_DISPOSITION_FORCED;
    video->codecpar->sample_aspect_ratio = (AVRational){4, 3};
    video->codecpar->color_range = AVCOL_RANGE_JPEG;
    video->codecpar->color_primaries = AVCOL_PRI_BT2020;
    video->codecpar->color_trc = AVCOL_TRC_SMPTE2084;
    video->codecpar->color_space = AVCOL_SPC_BT2020_NCL;
    video->codecpar->chroma_location = AVCHROMA_LOC_TOPLEFT;

    AVMasteringDisplayMetadata mastering = {0};
    mastering.has_primaries = 1;
    mastering.has_luminance = 1;
    mastering.display_primaries[0][0] = (AVRational){17, 50};
    mastering.display_primaries[0][1] = (AVRational){33, 100};
    mastering.display_primaries[1][0] = (AVRational){13, 50};
    mastering.display_primaries[1][1] = (AVRational){69, 100};
    mastering.display_primaries[2][0] = (AVRational){3, 20};
    mastering.display_primaries[2][1] = (AVRational){3, 50};
    mastering.white_point[0] = (AVRational){3127, 10000};
    mastering.white_point[1] = (AVRational){329, 1000};
    mastering.min_luminance = (AVRational){1, 10000};
    mastering.max_luminance = (AVRational){1000, 1};
    result = vpff_debug_add_side_data(
        video->codecpar,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
        &mastering,
        sizeof(mastering)
    );
    AVContentLightMetadata light = {.MaxCLL = 1000, .MaxFALL = 400};
    if (result >= 0) {
        result = vpff_debug_add_side_data(
            video->codecpar,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
            &light,
            sizeof(light)
        );
    }

    audio->disposition = AV_DISPOSITION_COMMENT;
    enum AVAudioServiceType service = AV_AUDIO_SERVICE_TYPE_COMMENTARY;
    if (result >= 0) {
        result = vpff_debug_add_side_data(
            audio->codecpar,
            AV_PKT_DATA_AUDIO_SERVICE_TYPE,
            &service,
            sizeof(service)
        );
    }
    return result;
}

static int vpff_debug_set_audio_service(
    AVCodecParameters *parameters,
    enum AVAudioServiceType service
) {
    return vpff_debug_add_side_data(
        parameters,
        AV_PKT_DATA_AUDIO_SERVICE_TYPE,
        &service,
        sizeof(service)
    );
}

static int vpff_debug_update_mastering_display(
    AVCodecParameters *parameters,
    bool use_zero_minimum,
    bool use_invalid_chromaticity,
    bool use_invalid_chromaticity_sum
) {
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA
    );
    if (side_data == NULL || side_data->data == NULL ||
        side_data->size < sizeof(AVMasteringDisplayMetadata)) {
        return AVERROR_INVALIDDATA;
    }
    AVMasteringDisplayMetadata metadata;
    memcpy(&metadata, side_data->data, sizeof(metadata));
    if (use_zero_minimum) {
        metadata.min_luminance = (AVRational){0, 1};
    }
    if (use_invalid_chromaticity) {
        metadata.display_primaries[0][0] = (AVRational){2, 1};
    }
    if (use_invalid_chromaticity_sum) {
        metadata.display_primaries[0][0] = (AVRational){3, 5};
        metadata.display_primaries[0][1] = (AVRational){1, 2};
    }
    memcpy(side_data->data, &metadata, sizeof(metadata));
    return 0;
}

static int vpff_debug_update_content_light(
    AVCodecParameters *parameters,
    unsigned maximum_content_light_level,
    unsigned maximum_frame_average_light_level
) {
    const AVPacketSideData *side_data = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL
    );
    if (side_data == NULL || side_data->data == NULL ||
        side_data->size < sizeof(AVContentLightMetadata)) {
        return AVERROR_INVALIDDATA;
    }
    AVContentLightMetadata metadata = {
        .MaxCLL = maximum_content_light_level,
        .MaxFALL = maximum_frame_average_light_level,
    };
    memcpy(side_data->data, &metadata, sizeof(metadata));
    return 0;
}

static int vpff_debug_fill_track_set(
    AVFormatContext *format,
    bool has_video,
    bool has_audio,
    VPFFOwnedTrackSet *tracks
) {
    VPFFOwnedTrackSet borrowed = {0};
    int result = has_video
        ? vpff_fill_video_track(
            &borrowed.video,
            format->streams[0],
            format->streams[0]->codecpar,
            format->streams[0]->time_base,
            (AVRational){30000, 1001}
        )
        : 0;
    if (result >= 0 && has_audio) {
        result = vpff_fill_audio_track(
            &borrowed.audio,
            format->streams[1],
            format->streams[1]->codecpar,
            format->streams[1]->time_base
        );
    }
    if (result >= 0 && has_video) {
        result = vpff_copy_borrowed_track(&tracks->video, &borrowed.video);
    }
    if (result >= 0 && has_audio) {
        result = vpff_copy_borrowed_track(&tracks->audio, &borrowed.audio);
    }
    if (result < 0) {
        vpff_owned_track_set_clear(tracks);
    }
    return result;
}

static int vpff_debug_add_audio_stream(AVFormatContext *format, int codec_id) {
    AVStream *audio = avformat_new_stream(format, NULL);
    if (audio == NULL) return AVERROR(ENOMEM);
    audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    audio->codecpar->codec_id = codec_id;
    audio->codecpar->sample_rate = 48000;
    audio->time_base = (AVRational){1, 48000};
    return av_channel_layout_from_mask(&audio->codecpar->ch_layout, AV_CH_LAYOUT_STEREO);
}

static int vpff_debug_add_program_members(AVFormatContext *format) {
    AVProgram *program = av_new_program(format, 1);
    if (program == NULL) return AVERROR(ENOMEM);
    for (unsigned int index = 0; index < format->nb_streams; index += 1) {
        av_program_add_stream_index(format, program->id, index);
    }
    return 0;
}

static bool vpff_debug_is_primary_scenario(VPFFTrackExtrasDebugScenario scenario) {
    return scenario >= VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_SOLE &&
           scenario <= VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_FORMAT_SCOPE;
}

int32_t vp_ffmpeg_demuxer_debug_emit_track_extras(
    VPFFTrackExtrasDebugScenario scenario,
    VPFFDemuxCallbackV2 callback,
    void *context
) {
    if (callback == NULL) {
        return AVERROR(EINVAL);
    }
    AVFormatContext *format = vpff_bootstrap_debug_format();
    if (format == NULL) {
        return AVERROR(ENOMEM);
    }
    format->streams[0]->codecpar->width = 1920;
    format->streams[0]->codecpar->height = 1080;

    bool has_video = false;
    bool has_audio = false;
    int result = 0;
    switch (scenario) {
    case VPFF_TRACK_EXTRAS_DEBUG_FULL_EVIDENCE:
        has_video = true;
        has_audio = true;
        result = vpff_debug_configure_full_track_evidence(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_DEFAULT_ONLY:
        has_audio = true;
        format->streams[1]->disposition = AV_DISPOSITION_DEFAULT;
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_FORMAT_DRIFT:
        has_video = true;
        result = vpff_debug_configure_full_track_evidence(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_AUDIO_SERVICE_MAIN:
        has_audio = true;
        result = vpff_debug_set_audio_service(
            format->streams[1]->codecpar,
            AV_AUDIO_SERVICE_TYPE_MAIN
        );
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_SERVICE_CONFLICT:
        has_audio = true;
        format->streams[1]->codecpar->codec_id = AV_CODEC_ID_EAC3;
        format->streams[1]->codecpar->profile = AV_PROFILE_EAC3_DDP_ATMOS;
        result = av_dict_set(
            &format->streams[1]->metadata,
            "service",
            "associated",
            0
        );
        if (result >= 0) {
            result = vpff_debug_set_audio_service(
                format->streams[1]->codecpar,
                AV_AUDIO_SERVICE_TYPE_MAIN
            );
        }
        if (result >= 0) {
            format->streams[1]->disposition = AV_DISPOSITION_DEPENDENT;
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_SERVICE_TOKEN:
        has_audio = true;
        result = av_dict_set(&format->streams[1]->metadata, "role", "main", 0);
        if (result >= 0) {
            result = av_dict_set(
                &format->streams[1]->metadata,
                "service",
                "future_service_value",
                0
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_TOKEN:
        has_audio = true;
        result = av_dict_set(&format->streams[1]->metadata, "role",
                             "future_primary_role", 0);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_COMMENT:
        has_audio = true;
        result = av_dict_set(&format->streams[1]->metadata, "role",
                             "future_primary_role", 0);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_COMMENT;
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_DUB:
        has_audio = true;
        result = av_dict_set(&format->streams[1]->metadata, "role",
                             "future_primary_role", 0);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_DUB;
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_KARAOKE_SERVICE:
        has_audio = true;
        result = av_dict_set(&format->streams[1]->metadata, "role", "main", 0);
        if (result >= 0) {
            result = vpff_debug_set_audio_service(
                format->streams[1]->codecpar,
                AV_AUDIO_SERVICE_TYPE_KARAOKE
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_MALFORMED_AUDIO_SERVICE: {
        has_audio = true;
        uint8_t malformed_service = 0;
        result = vpff_debug_add_side_data(
            format->streams[1]->codecpar,
            AV_PKT_DATA_AUDIO_SERVICE_TYPE,
            &malformed_service,
            sizeof(malformed_service)
        );
        break;
    }
    case VPFF_TRACK_EXTRAS_DEBUG_ZERO_MIN_LUMINANCE:
        has_video = true;
        result = vpff_debug_configure_full_track_evidence(format);
        if (result >= 0) {
            result = vpff_debug_update_mastering_display(
                format->streams[0]->codecpar,
                true,
                false,
                false
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY:
        has_video = true;
        result = vpff_debug_configure_full_track_evidence(format);
        if (result >= 0) {
            result = vpff_debug_update_mastering_display(
                format->streams[0]->codecpar,
                false,
                true,
                false
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_INVALID_CONTENT_LIGHT_LEVEL:
        has_video = true;
        result = vpff_debug_configure_full_track_evidence(format);
        if (result >= 0) {
            result = vpff_debug_update_content_light(
                format->streams[0]->codecpar,
                400,
                1000
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY_SUM:
        has_video = true;
        result = vpff_debug_configure_full_track_evidence(format);
        if (result >= 0) {
            result = vpff_debug_update_mastering_display(
                format->streams[0]->codecpar,
                false,
                false,
                true
            );
        }
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_SOLE:
        has_audio = true;
        result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_PCM_S16LE);
        if (result >= 0) result = av_dict_set(&format->streams[1]->metadata, "role", "main", 0);
        if (result >= 0) result = av_dict_set(&format->streams[2]->metadata, "role", "alternate", 0);
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNIQUE_DEFAULT:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_DEFAULT;
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_AMBIGUOUS:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MULTI_DEFAULT:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_DEFAULT;
        if (result >= 0) format->streams[2]->disposition = AV_DISPOSITION_DEFAULT;
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN_DEFAULT_COMPETITION:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) result = av_dict_set(&format->streams[1]->metadata, "role", "main", 0);
        if (result >= 0) format->streams[2]->disposition = AV_DISPOSITION_DEFAULT;
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNKNOWN_OR_AUXILIARY:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) result = av_dict_set(&format->streams[1]->metadata, "role", "future_role", 0);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_COMMENT;
        if (result >= 0) result = vpff_debug_add_program_members(format);
        break;
    case VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_FORMAT_SCOPE:
        has_audio = true;
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_DEFAULT;
        break;
    default:
        result = AVERROR(EINVAL);
        break;
    }

    VPFFOwnedTrackSet first = {0};
    if (result >= 0 && vpff_debug_is_primary_scenario(scenario)) {
        /* 此 debug probe 只校验音频 scope；避免为未使用的视频 remux 构造伪 filter。 */
        format->streams[0]->codecpar->codec_type = AVMEDIA_TYPE_DATA;
        VPFFSelection selection = {0};
        VPFFFailure selection_failure = {0};
        result = vpff_select_streams(format, &selection, &selection_failure);
        if (result >= 0) {
            result = vpff_make_track_set(&first, format, &selection, NULL,
                                         format->streams[selection.audio_stream_index]->codecpar,
                                         format->streams[selection.audio_stream_index]->time_base);
        }
    } else if (result >= 0) {
        result = vpff_debug_fill_track_set(format, has_video, has_audio, &first);
    }
    VPDemuxer demuxer = {
        .callback_v2 = callback,
        .context = context,
    };
    if (result >= 0) {
        vpff_emit_tracks(
            &demuxer,
            VPFF_EVENT_TRACKS,
            VPFF_DISCONTINUITY_NONE,
            &first
        );
    }

    VPFFOwnedTrackSet second = {0};
    if (result >= 0 && scenario == VPFF_TRACK_EXTRAS_DEBUG_FORMAT_DRIFT) {
        result = vpff_debug_update_content_light(
            format->streams[0]->codecpar,
            2000,
            800
        );
        if (result >= 0) {
            result = vpff_debug_fill_track_set(format, true, false, &second);
        }
        if (result >= 0 && vpff_track_sets_equal(&first, &second)) {
            result = AVERROR_BUG;
        }
        if (result >= 0) {
            vpff_emit_tracks(
                &demuxer,
                VPFF_EVENT_DISCONTINUITY,
                VPFF_DISCONTINUITY_FORMAT_CHANGE,
                &second
            );
        }
    }

    vpff_owned_track_set_clear(&second);
    vpff_owned_track_set_clear(&first);
    avformat_free_context(format);
    return (int32_t)result;
}

typedef struct { uint32_t discontinuity_count; } VPFFPrimaryRefreshDebugObserver;

static void vpff_debug_refresh_callback(
    void *context, const VPFFDemuxEvent *event, const VPFFDemuxEventExtras *extras
) {
    (void)extras;
    VPFFPrimaryRefreshDebugObserver *observer = context;
    if (observer != NULL && event != NULL && event->kind == VPFF_EVENT_DISCONTINUITY) {
        observer->discontinuity_count += 1;
    }
}

int32_t vp_ffmpeg_demuxer_debug_refresh_audio_primary(
    VPFFPrimaryRefreshDebugScenario scenario,
    VPFFPrimaryRefreshDebugResult *out_result
) {
    if (out_result == NULL) return AVERROR(EINVAL);
    memset(out_result, 0, sizeof(*out_result));
    AVFormatContext *format = vpff_bootstrap_debug_format();
    VPFFOwnedTrackSet current = {0};
    AVCodecParameters *audio_key = NULL;
    AVCodecParameters *audio_source_key = NULL;
    int result = format == NULL ? AVERROR(ENOMEM) : vpff_debug_add_program_members(format);
    if (result >= 0 && (scenario == VPFF_PRIMARY_REFRESH_DEBUG_DEFAULT_DRIFT ||
                        scenario == VPFF_PRIMARY_REFRESH_DEBUG_ROLE_DRIFT)) {
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) format->streams[1]->disposition = AV_DISPOSITION_DEFAULT;
        if (result >= 0) av_program_add_stream_index(format, 1, 2);
    }
    format->streams[0]->codecpar->codec_type = AVMEDIA_TYPE_DATA;
    VPFFSelection selection = {0};
    VPFFFailure failure = {0};
    if (result >= 0) result = vpff_select_streams(format, &selection, &failure);
    if (result >= 0) result = vpff_make_track_set(&current, format, &selection, NULL,
        format->streams[selection.audio_stream_index]->codecpar,
        format->streams[selection.audio_stream_index]->time_base);
    if (result >= 0) {
        out_result->initial_audio_count = current.audio_primary_evidence.audio_stream_count;
        out_result->initial_basis = current.audio_primary_evidence.primary_basis;
        result = vpff_copy_effective_parameters(&audio_key,
            format->streams[selection.audio_stream_index]->codecpar, NULL);
    }
    if (result >= 0) result = vpff_copy_effective_parameters(&audio_source_key,
        format->streams[selection.audio_stream_index]->codecpar, NULL);
    if (result >= 0 && scenario == VPFF_PRIMARY_REFRESH_DEBUG_COMPETING_AUDIO) {
        result = vpff_debug_add_audio_stream(format, AV_CODEC_ID_AC3);
        if (result >= 0) av_program_add_stream_index(format, 1, 2);
    } else if (result >= 0 && scenario == VPFF_PRIMARY_REFRESH_DEBUG_DEFAULT_DRIFT) {
        format->streams[2]->disposition = AV_DISPOSITION_DEFAULT;
        if (av_dict_set(&format->streams[2]->metadata, "role", "alternate", 0) < 0) {
            result = AVERROR(ENOMEM);
        }
    } else if (result >= 0 && scenario == VPFF_PRIMARY_REFRESH_DEBUG_ROLE_DRIFT) {
        if (av_dict_set(&format->streams[2]->metadata, "role", "main", 0) < 0) {
            result = AVERROR(ENOMEM);
        }
    } else if (result >= 0 && scenario == VPFF_PRIMARY_REFRESH_DEBUG_SELECTED_REMOVED) {
        format->programs[0]->nb_stream_indexes = 1;
    }
    AVPacket packet = { .stream_index = selection.audio_stream_index };
    AVRational audio_time_base = format->streams[selection.audio_stream_index]->time_base;
    VPFFPrimaryRefreshDebugObserver observer = {0};
    VPDemuxer demuxer = { .callback_v2 = vpff_debug_refresh_callback, .context = &observer };
    if (result >= 0) result = vpff_update_selected_tracks(format, &selection, &packet, NULL,
        &audio_key, &audio_source_key, &audio_time_base, &current, &demuxer, &failure);
    out_result->status = result;
    out_result->refreshed_audio_count = current.audio_primary_evidence.audio_stream_count;
    out_result->refreshed_basis = current.audio_primary_evidence.primary_basis;
    out_result->discontinuity_count = observer.discontinuity_count;
    avcodec_parameters_free(&audio_key);
    avcodec_parameters_free(&audio_source_key);
    vpff_owned_track_set_clear(&current);
    avformat_free_context(format);
    return result;
}
#endif
