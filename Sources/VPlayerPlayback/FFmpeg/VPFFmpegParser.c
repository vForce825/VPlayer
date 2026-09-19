// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegParser.h"

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/rational.h>
#pragma clang diagnostic pop

#define VPFF_MAX_PARSER_BYTES ((size_t)64 * 1024 * 1024)

struct VPFFParser {
    AVCodecParserContext *parser;
    AVCodecContext *codec_context;
    VPFFParserCallback callback;
    void *callback_context;
    int32_t time_base_num;
    int32_t time_base_den;
    int64_t input_position;
    size_t bytes_without_output;
    bool drained;
    VPFFParserAllocationCallbacks allocation_callbacks;
    void *extradata_reservation;
};

static enum AVCodecID vpff_parser_codec_id(VPFFCodec codec) {
    switch (codec) {
        case VPFF_CODEC_H264:
            return AV_CODEC_ID_H264;
        case VPFF_CODEC_HEVC:
            return AV_CODEC_ID_HEVC;
        case VPFF_CODEC_AAC:
            return AV_CODEC_ID_AAC;
        case VPFF_CODEC_AC3:
            return AV_CODEC_ID_AC3;
        case VPFF_CODEC_EAC3:
            return AV_CODEC_ID_EAC3;
        case VPFF_CODEC_MP2:
            return AV_CODEC_ID_MP2;
        case VPFF_CODEC_MP1:
            return AV_CODEC_ID_MP1;
        case VPFF_CODEC_MP3:
            return AV_CODEC_ID_MP3;
        case VPFF_CODEC_UNSUPPORTED:
            return AV_CODEC_ID_NONE;
    }
    return AV_CODEC_ID_NONE;
}

static bool vpff_parser_is_audio(VPFFCodec codec) {
    return codec == VPFF_CODEC_AAC || codec == VPFF_CODEC_AC3 ||
           codec == VPFF_CODEC_EAC3 || codec == VPFF_CODEC_MP1 ||
           codec == VPFF_CODEC_MP2 || codec == VPFF_CODEC_MP3;
}

static bool vpff_parser_valid_pointer_size(const void *pointer, size_t size) {
    return (pointer == NULL) == (size == 0);
}

static bool vpff_parser_valid_channel_order(VPFFChannelOrder order) {
    return order == VPFF_CHANNEL_ORDER_UNSPECIFIED ||
           order == VPFF_CHANNEL_ORDER_NATIVE;
}

static bool vpff_parser_validate_config(const VPFFParserConfigV1 *config) {
    if (config == NULL || config->abi_version != VPFF_PARSER_ABI_VERSION ||
        config->struct_size != sizeof(VPFFParserConfigV1) ||
        config->time_base_num <= 0 || config->time_base_den <= 0 ||
        config->has_channel_layout_mask > 1 ||
        !vpff_parser_valid_pointer_size(config->extradata, config->extradata_size) ||
        config->extradata_size > VPFF_MAX_PARSER_BYTES ||
        vpff_parser_codec_id(config->codec) == AV_CODEC_ID_NONE) {
        return false;
    }

    if (!vpff_parser_is_audio(config->codec)) {
        return config->sample_rate == 0 && config->channel_count == 0 &&
               config->channel_order == VPFF_CHANNEL_ORDER_UNSPECIFIED &&
               config->has_channel_layout_mask == 0 &&
               config->channel_layout_mask == 0;
    }

    if (config->sample_rate <= 0 || config->channel_count <= 0 ||
        !vpff_parser_valid_channel_order(config->channel_order)) {
        return false;
    }
    if (config->channel_order == VPFF_CHANNEL_ORDER_UNSPECIFIED) {
        return config->has_channel_layout_mask == 0 &&
               config->channel_layout_mask == 0;
    }
    if (config->has_channel_layout_mask != 1 || config->channel_layout_mask == 0) {
        return false;
    }
    return __builtin_popcountll(config->channel_layout_mask) == config->channel_count;
}

static bool vpff_parser_valid_allocation_callbacks(
    const VPFFParserAllocationCallbacks *callbacks
) {
    return (callbacks->reserve == NULL && callbacks->release == NULL) ||
           (callbacks->reserve != NULL && callbacks->release != NULL);
}

static void *vpff_parser_reserve(
    VPFFParser *owned,
    VPFFParserAllocationKind kind,
    size_t bytes
) {
    if (owned->allocation_callbacks.reserve == NULL) {
        return (void *)owned;
    }
    return owned->allocation_callbacks.reserve(
        owned->allocation_callbacks.context,
        kind,
        bytes
    );
}

static void vpff_parser_release(VPFFParser *owned, void *reservation) {
    if (owned->allocation_callbacks.release != NULL && reservation != NULL) {
        owned->allocation_callbacks.release(owned->allocation_callbacks.context, reservation);
    }
}

static int vpff_parser_copy_extradata(
    VPFFParser *owned,
    const uint8_t *extradata,
    size_t extradata_size
) {
    if (extradata_size == 0) {
        return 0;
    }
    if (extradata_size > (size_t)INT_MAX ||
        extradata_size > SIZE_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
        return AVERROR(EOVERFLOW);
    }
    size_t allocation_size = extradata_size + AV_INPUT_BUFFER_PADDING_SIZE;
    void *reservation = vpff_parser_reserve(
        owned,
        VPFF_PARSER_ALLOCATION_EXTRADATA,
        allocation_size
    );
    if (reservation == NULL) {
        return AVERROR(EAGAIN);
    }
    owned->codec_context->extradata = av_mallocz(allocation_size);
    if (owned->codec_context->extradata == NULL) {
        vpff_parser_release(owned, reservation);
        return AVERROR(ENOMEM);
    }
    owned->extradata_reservation = reservation;
    memcpy(owned->codec_context->extradata, extradata, extradata_size);
    owned->codec_context->extradata_size = (int)extradata_size;
    return 0;
}

static int vpff_parser_configure_channel_layout(
    AVCodecContext *codec_context,
    const VPFFParserConfigV1 *config
) {
    if (!vpff_parser_is_audio(config->codec)) {
        return 0;
    }
    codec_context->sample_rate = config->sample_rate;
    if (config->channel_order == VPFF_CHANNEL_ORDER_NATIVE) {
        int result = av_channel_layout_from_mask(
            &codec_context->ch_layout,
            config->channel_layout_mask
        );
        if (result < 0) {
            return result;
        }
        if (codec_context->ch_layout.nb_channels != config->channel_count) {
            return AVERROR(EINVAL);
        }
        return 0;
    }
    codec_context->ch_layout.order = AV_CHANNEL_ORDER_UNSPEC;
    codec_context->ch_layout.nb_channels = config->channel_count;
    return 0;
}

static int32_t vpff_parser_create(
    const VPFFParserConfigV1 *config,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser,
    const VPFFParserAllocationCallbacks *allocation_callbacks
) {
    if (out_parser == NULL) {
        return AVERROR(EINVAL);
    }
    *out_parser = NULL;
    if (!vpff_parser_validate_config(config) || callback == NULL) {
        return AVERROR(EINVAL);
    }

    enum AVCodecID codec_id = vpff_parser_codec_id(config->codec);
    VPFFParser *owned = calloc(1, sizeof(*owned));
    if (owned == NULL) {
        return AVERROR(ENOMEM);
    }
    if (allocation_callbacks != NULL) {
        owned->allocation_callbacks = *allocation_callbacks;
    }
    owned->parser = av_parser_init(codec_id);
    owned->codec_context = avcodec_alloc_context3(NULL);
    if (owned->parser == NULL || owned->codec_context == NULL) {
        vp_ffmpeg_parser_destroy(owned);
        return AVERROR(ENOMEM);
    }

    owned->codec_context->codec_id = codec_id;
    owned->codec_context->codec_type = vpff_parser_is_audio(config->codec)
        ? AVMEDIA_TYPE_AUDIO
        : AVMEDIA_TYPE_VIDEO;
    owned->codec_context->pkt_timebase = (AVRational){
        .num = config->time_base_num,
        .den = config->time_base_den,
    };
    owned->codec_context->time_base = owned->codec_context->pkt_timebase;

    int result = vpff_parser_configure_channel_layout(owned->codec_context, config);
    if (result >= 0) {
        result = vpff_parser_copy_extradata(
            owned,
            config->extradata,
            config->extradata_size
        );
    }
    if (result < 0) {
        vp_ffmpeg_parser_destroy(owned);
        return result;
    }

    owned->callback = callback;
    owned->callback_context = context;
    owned->time_base_num = config->time_base_num;
    owned->time_base_den = config->time_base_den;
    *out_parser = owned;
    return 0;
}

int32_t vp_ffmpeg_parser_create_v1(
    const VPFFParserConfigV1 *config,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
) {
    return vpff_parser_create(config, callback, context, out_parser, NULL);
}

int32_t vp_ffmpeg_parser_create_v2(
    const VPFFParserConfigV2 *config,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
) {
    if (config == NULL || config->abi_version != VPFF_PARSER_ABI_VERSION_V2 ||
        config->struct_size != sizeof(VPFFParserConfigV2) ||
        !vpff_parser_valid_allocation_callbacks(&config->allocation_callbacks)) {
        if (out_parser != NULL) { *out_parser = NULL; }
        return AVERROR(EINVAL);
    }
    VPFFParserConfigV1 v1 = {
        .abi_version = VPFF_PARSER_ABI_VERSION,
        .struct_size = sizeof(VPFFParserConfigV1),
        .codec = config->codec,
        .time_base_num = config->time_base_num,
        .time_base_den = config->time_base_den,
        .sample_rate = config->sample_rate,
        .channel_count = config->channel_count,
        .channel_order = config->channel_order,
        .has_channel_layout_mask = config->has_channel_layout_mask,
        .channel_layout_mask = config->channel_layout_mask,
        .extradata = config->extradata,
        .extradata_size = config->extradata_size,
    };
    return vpff_parser_create(
        &v1,
        callback,
        context,
        out_parser,
        &config->allocation_callbacks
    );
}

int32_t vp_ffmpeg_parser_create(
    VPFFCodec codec,
    const uint8_t *extradata,
    size_t extradata_size,
    VPFFParserCallback callback,
    void *context,
    VPFFParser **out_parser
) {
    if (codec != VPFF_CODEC_H264 && codec != VPFF_CODEC_HEVC) {
        if (out_parser != NULL) {
            *out_parser = NULL;
        }
        return AVERROR(EINVAL);
    }
    VPFFParserConfigV1 config = {
        .abi_version = VPFF_PARSER_ABI_VERSION,
        .struct_size = sizeof(VPFFParserConfigV1),
        .codec = codec,
        .time_base_num = 1,
        .time_base_den = 90000,
        .sample_rate = 0,
        .channel_count = 0,
        .channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED,
        .has_channel_layout_mask = 0,
        .channel_layout_mask = 0,
        .extradata = extradata,
        .extradata_size = extradata_size,
    };
    return vp_ffmpeg_parser_create_v1(&config, callback, context, out_parser);
}

static int vpff_parser_map_field_order(enum AVFieldOrder value, int32_t *mapped) {
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

static int vpff_parser_map_picture_structure(
    enum AVPictureStructure value,
    int32_t *mapped
) {
    switch (value) {
        case AV_PICTURE_STRUCTURE_UNKNOWN:
            *mapped = VPFF_PICTURE_STRUCTURE_UNKNOWN;
            return 0;
        case AV_PICTURE_STRUCTURE_FRAME:
            *mapped = VPFF_PICTURE_STRUCTURE_FRAME;
            return 0;
        case AV_PICTURE_STRUCTURE_TOP_FIELD:
            *mapped = VPFF_PICTURE_STRUCTURE_TOP_FIELD;
            return 0;
        case AV_PICTURE_STRUCTURE_BOTTOM_FIELD:
            *mapped = VPFF_PICTURE_STRUCTURE_BOTTOM_FIELD;
            return 0;
    }
    return AVERROR_INVALIDDATA;
}

static int8_t vpff_parser_interlaced(const VPFFParsedFrame *frame) {
    if (frame->field_order == VPFF_FIELD_ORDER_PROGRESSIVE) {
        return 0;
    }
    if (frame->field_order == VPFF_FIELD_ORDER_TT ||
        frame->field_order == VPFF_FIELD_ORDER_BB ||
        frame->field_order == VPFF_FIELD_ORDER_TB ||
        frame->field_order == VPFF_FIELD_ORDER_BT ||
        frame->picture_structure == VPFF_PICTURE_STRUCTURE_TOP_FIELD ||
        frame->picture_structure == VPFF_PICTURE_STRUCTURE_BOTTOM_FIELD) {
        return 1;
    }
    return -1;
}

static int8_t vpff_parser_top_field_first(const VPFFParsedFrame *frame) {
    if (frame->field_order == VPFF_FIELD_ORDER_TT ||
        frame->field_order == VPFF_FIELD_ORDER_BT ||
        frame->picture_structure == VPFF_PICTURE_STRUCTURE_TOP_FIELD) {
        return 1;
    }
    if (frame->field_order == VPFF_FIELD_ORDER_BB ||
        frame->field_order == VPFF_FIELD_ORDER_TB ||
        frame->picture_structure == VPFF_PICTURE_STRUCTURE_BOTTOM_FIELD) {
        return 0;
    }
    return -1;
}

#if DEBUG
int8_t vp_ffmpeg_parser_debug_top_field_first(
    int32_t field_order,
    int32_t picture_structure
) {
    const VPFFParsedFrame frame = {
        .field_order = field_order,
        .picture_structure = picture_structure,
    };
    return vpff_parser_top_field_first(&frame);
}
#endif

static int vpff_parser_emit(
    VPFFParser *owned,
    const uint8_t *output,
    int output_size
) {
    if (output == NULL || output_size <= 0 || (size_t)output_size > VPFF_MAX_PARSER_BYTES) {
        return AVERROR_INVALIDDATA;
    }

    VPFFParsedFrame frame = {0};
    frame.bytes = output;
    frame.size = (size_t)output_size;
    frame.pts = owned->parser->pts;
    frame.dts = owned->parser->dts;
    frame.duration = owned->parser->duration > 0
        ? owned->parser->duration
        : AV_NOPTS_VALUE;
    frame.key_frame = (int8_t)(owned->parser->key_frame == 0 || owned->parser->key_frame == 1
        ? owned->parser->key_frame
        : -1);
    frame.repeat_pict = owned->parser->repeat_pict > 0 ? 1 : 0;
    frame.sample_rate = owned->codec_context->sample_rate;
    frame.channels = owned->codec_context->ch_layout.nb_channels;
    frame.frame_samples = owned->parser->duration > 0 ? owned->parser->duration : 0;
    frame.duration_value = AV_NOPTS_VALUE;
    frame.duration_timescale = 0;
    frame.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED;

    int result = vpff_parser_map_field_order(owned->parser->field_order, &frame.field_order);
    if (result >= 0) {
        result = vpff_parser_map_picture_structure(
            owned->parser->picture_structure,
            &frame.picture_structure
        );
    }
    if (result < 0) {
        return result;
    }
    frame.interlaced = vpff_parser_interlaced(&frame);
    frame.top_field_first = vpff_parser_top_field_first(&frame);

    if (owned->codec_context->codec_id == AV_CODEC_ID_HEVC && frame.field_order == VPFF_FIELD_ORDER_UNKNOWN) {
        frame.field_order = VPFF_FIELD_ORDER_PROGRESSIVE;
        frame.picture_structure = VPFF_PICTURE_STRUCTURE_FRAME;
        frame.interlaced = 0;
    }

    if (owned->codec_context->codec_type == AVMEDIA_TYPE_AUDIO &&
        frame.frame_samples > 0 && frame.sample_rate > 0) {
        frame.duration_value = frame.frame_samples;
        frame.duration_timescale = frame.sample_rate;
    } else if (owned->parser->duration > 0) {
        int64_t scaled;
        if (__builtin_mul_overflow(
                (int64_t)owned->parser->duration,
                (int64_t)owned->time_base_num,
                &scaled
            )) {
            return AVERROR(EOVERFLOW);
        }
        frame.duration_value = scaled;
        frame.duration_timescale = owned->time_base_den;
    }

    if (owned->codec_context->ch_layout.order == AV_CHANNEL_ORDER_NATIVE) {
        frame.channel_order = VPFF_CHANNEL_ORDER_NATIVE;
        frame.has_channel_layout_mask = 1;
        frame.channel_layout_mask = owned->codec_context->ch_layout.u.mask;
    }

    owned->callback(owned->callback_context, &frame);
    owned->bytes_without_output = 0;
    return 0;
}

static int vpff_parser_parse_owned_input(
    VPFFParser *owned,
    const uint8_t *input,
    size_t size,
    int64_t pts,
    int64_t dts
) {
    size_t offset = 0;
    bool zero_consumed_output = false;
    while (offset < size) {
        size_t remaining = size - offset;
        if (remaining > (size_t)INT_MAX) {
            return AVERROR(EOVERFLOW);
        }
        uint8_t *output = NULL;
        int output_size = 0;
        int consumed = av_parser_parse2(
            owned->parser,
            owned->codec_context,
            &output,
            &output_size,
            input + offset,
            (int)remaining,
            pts,
            dts,
            owned->input_position + (int64_t)offset
        );
        if (consumed < 0 || (size_t)consumed > remaining) {
            return AVERROR_INVALIDDATA;
        }
        if (consumed == 0 && output_size == 0) {
            return AVERROR_INVALIDDATA;
        }
        if (consumed == 0 && output_size > 0) {
            if (zero_consumed_output) {
                return AVERROR_INVALIDDATA;
            }
            zero_consumed_output = true;
        } else {
            zero_consumed_output = false;
        }

        if (consumed > 0) {
            size_t consumed_size = (size_t)consumed;
            if (owned->bytes_without_output > VPFF_MAX_PARSER_BYTES - consumed_size) {
                return AVERROR_INVALIDDATA;
            }
            owned->bytes_without_output += consumed_size;
            offset += consumed_size;
        }
        if (output_size > 0) {
            int result = vpff_parser_emit(owned, output, output_size);
            if (result < 0) {
                return result;
            }
        }
    }
    return 0;
}

int32_t vp_ffmpeg_parser_push(
    VPFFParser *owned,
    const uint8_t *bytes,
    size_t size,
    int64_t pts,
    int64_t dts,
    int64_t duration
) {
    if (owned == NULL || owned->drained || !vpff_parser_valid_pointer_size(bytes, size) ||
        size == 0 || size > VPFF_MAX_PARSER_BYTES ||
        (duration < 0 && duration != AV_NOPTS_VALUE) ||
        size > (size_t)(INT64_MAX - owned->input_position) ||
        size > SIZE_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
        return AVERROR(EINVAL);
    }
    (void)duration;

    size_t allocation_size = size + AV_INPUT_BUFFER_PADDING_SIZE;
    void *reservation = vpff_parser_reserve(
        owned,
        VPFF_PARSER_ALLOCATION_PUSH_INPUT,
        allocation_size
    );
    if (reservation == NULL) {
        return AVERROR(EAGAIN);
    }
    uint8_t *copy = av_mallocz(allocation_size);
    if (copy == NULL) {
        vpff_parser_release(owned, reservation);
        return AVERROR(ENOMEM);
    }
    memcpy(copy, bytes, size);
    int result = vpff_parser_parse_owned_input(owned, copy, size, pts, dts);
    av_free(copy);
    vpff_parser_release(owned, reservation);
    if (result >= 0) {
        owned->input_position += (int64_t)size;
    }
    return result;
}

int32_t vp_ffmpeg_parser_drain(VPFFParser *owned) {
    if (owned == NULL) {
        return AVERROR(EINVAL);
    }
    if (owned->drained) {
        return 0;
    }

    for (;;) {
        uint8_t *output = NULL;
        int output_size = 0;
        int consumed = av_parser_parse2(
            owned->parser,
            owned->codec_context,
            &output,
            &output_size,
            NULL,
            0,
            AV_NOPTS_VALUE,
            AV_NOPTS_VALUE,
            owned->input_position
        );
        if (consumed != 0) {
            return AVERROR_INVALIDDATA;
        }
        if (output_size == 0) {
            owned->drained = true;
            owned->bytes_without_output = 0;
            return 0;
        }
        int result = vpff_parser_emit(owned, output, output_size);
        if (result < 0) {
            return result;
        }
    }
}

void vp_ffmpeg_parser_destroy(VPFFParser *owned) {
    if (owned == NULL) {
        return;
    }
    av_parser_close(owned->parser);
    avcodec_free_context(&owned->codec_context);
    vpff_parser_release(owned, owned->extradata_reservation);
    owned->extradata_reservation = NULL;
    free(owned);
}

size_t vp_ffmpeg_parser_input_padding_bytes(void) {
    return AV_INPUT_BUFFER_PADDING_SIZE;
}
