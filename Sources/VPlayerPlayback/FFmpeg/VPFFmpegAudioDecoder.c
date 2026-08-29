// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegAudioDecoder.h"

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libswresample/swresample.h>
#pragma clang diagnostic pop

#define VPFF_MAX_AUDIO_BYTES ((size_t)64 * 1024 * 1024)
#define VPFF_MAX_DISCRETE_CHANNELS 64
#define VPFF_CORE_AUDIO_NATIVE_MASK ((((uint64_t)1) << 18) - 1)

struct VPFFAudioDecoder {
    AVCodecContext *codec_context;
    AVPacket *packet;
    AVFrame *frame;
    SwrContext *resampler;
    enum AVSampleFormat input_format;
    int input_sample_rate;
    AVChannelLayout input_layout;
    AVChannelLayout output_layout;
    VPFFChannelOrder output_order;
    uint64_t output_mask;
    VPFFPCMCallback callback;
    void *callback_context;
    bool reached_eof;
};

static bool vpff_valid_pointer_size(const void *pointer, size_t size) {
    return (pointer == NULL) == (size == 0);
}

static enum AVCodecID vpff_audio_codec_id(VPFFCodec codec) {
    switch (codec) {
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
        case VPFF_CODEC_H264:
        case VPFF_CODEC_HEVC:
            return AV_CODEC_ID_NONE;
    }
    return AV_CODEC_ID_NONE;
}

static int vpff_copy_extradata(
    AVCodecContext *context,
    const uint8_t *extradata,
    size_t size
) {
    if (size == 0) {
        return 0;
    }
    if (size > VPFF_MAX_AUDIO_BYTES || size > (size_t)INT_MAX ||
        size > SIZE_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
        return AVERROR(EOVERFLOW);
    }
    context->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (context->extradata == NULL) {
        return AVERROR(ENOMEM);
    }
    memcpy(context->extradata, extradata, size);
    context->extradata_size = (int)size;
    return 0;
}

int32_t vp_ffmpeg_audio_decoder_create(
    VPFFCodec codec,
    const uint8_t *extradata,
    size_t extradata_size,
    VPFFPCMCallback callback,
    void *context,
    VPFFAudioDecoder **out_decoder
) {
    if (out_decoder == NULL) {
        return AVERROR(EINVAL);
    }
    *out_decoder = NULL;
    enum AVCodecID codec_id = vpff_audio_codec_id(codec);
    if (codec_id == AV_CODEC_ID_NONE || callback == NULL ||
        !vpff_valid_pointer_size(extradata, extradata_size) ||
        extradata_size > VPFF_MAX_AUDIO_BYTES) {
        return AVERROR(EINVAL);
    }

    const AVCodec *decoder = avcodec_find_decoder(codec_id);
    if (decoder == NULL) {
        return AVERROR_DECODER_NOT_FOUND;
    }
    VPFFAudioDecoder *owned = calloc(1, sizeof(*owned));
    if (owned == NULL) {
        return AVERROR(ENOMEM);
    }
    owned->codec_context = avcodec_alloc_context3(decoder);
    owned->packet = av_packet_alloc();
    owned->frame = av_frame_alloc();
    owned->input_format = AV_SAMPLE_FMT_NONE;
    if (owned->codec_context == NULL || owned->packet == NULL || owned->frame == NULL) {
        vp_ffmpeg_audio_decoder_destroy(owned);
        return AVERROR(ENOMEM);
    }
    owned->codec_context->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    int result = vpff_copy_extradata(owned->codec_context, extradata, extradata_size);
    if (result >= 0) {
        result = avcodec_open2(owned->codec_context, decoder, NULL);
    }
    if (result < 0) {
        vp_ffmpeg_audio_decoder_destroy(owned);
        return result;
    }
    owned->callback = callback;
    owned->callback_context = context;
    *out_decoder = owned;
    return 0;
}

static bool vpff_layout_is_representable_native(const AVChannelLayout *layout) {
    return layout->order == AV_CHANNEL_ORDER_NATIVE && layout->nb_channels > 0 &&
           layout->u.mask != 0 &&
           (layout->u.mask & ~VPFF_CORE_AUDIO_NATIVE_MASK) == 0 &&
           __builtin_popcountll(layout->u.mask) == layout->nb_channels;
}

static bool vpff_layout_is_representable_discrete(const AVChannelLayout *layout) {
    return layout->order == AV_CHANNEL_ORDER_UNSPEC && layout->nb_channels > 0 &&
           layout->nb_channels <= VPFF_MAX_DISCRETE_CHANNELS;
}

static int vpff_select_output_layout(
    const AVChannelLayout *input,
    AVChannelLayout *output,
    VPFFChannelOrder *order,
    uint64_t *mask
) {
    memset(output, 0, sizeof(*output));
    *mask = 0;
    if (vpff_layout_is_representable_native(input)) {
        int result = av_channel_layout_copy(output, input);
        if (result < 0) {
            return result;
        }
        *order = VPFF_CHANNEL_ORDER_NATIVE;
        *mask = input->u.mask;
        return 0;
    }
    if (vpff_layout_is_representable_discrete(input)) {
        output->order = AV_CHANNEL_ORDER_UNSPEC;
        output->nb_channels = input->nb_channels;
        *order = VPFF_CHANNEL_ORDER_UNSPECIFIED;
        return 0;
    }
    av_channel_layout_default(output, 2);
    if (!vpff_layout_is_representable_native(output)) {
        av_channel_layout_uninit(output);
        return AVERROR_INVALIDDATA;
    }
    *order = VPFF_CHANNEL_ORDER_NATIVE;
    *mask = output->u.mask;
    return 0;
}

static bool vpff_resampler_matches(VPFFAudioDecoder *owned, const AVFrame *frame) {
    return owned->resampler != NULL && owned->input_format == frame->format &&
           owned->input_sample_rate == frame->sample_rate &&
           av_channel_layout_compare(&owned->input_layout, &frame->ch_layout) == 0;
}

static int vpff_configure_resampler(VPFFAudioDecoder *owned, const AVFrame *frame) {
    if (vpff_resampler_matches(owned, frame)) {
        return 0;
    }

    AVChannelLayout candidate_output = {0};
    VPFFChannelOrder candidate_order = VPFF_CHANNEL_ORDER_UNSPECIFIED;
    uint64_t candidate_mask = 0;
    int result = vpff_select_output_layout(
        &frame->ch_layout,
        &candidate_output,
        &candidate_order,
        &candidate_mask
    );
    if (result < 0) {
        return result;
    }

    SwrContext *candidate = NULL;
    result = swr_alloc_set_opts2(
        &candidate,
        &candidate_output,
        AV_SAMPLE_FMT_FLT,
        frame->sample_rate,
        &frame->ch_layout,
        (enum AVSampleFormat)frame->format,
        frame->sample_rate,
        0,
        NULL
    );
    if (result >= 0 && candidate != NULL) {
        result = swr_init(candidate);
    }
    if (result < 0 || candidate == NULL) {
        swr_free(&candidate);
        av_channel_layout_uninit(&candidate_output);
        return result < 0 ? result : AVERROR(ENOMEM);
    }

    AVChannelLayout candidate_input = {0};
    result = av_channel_layout_copy(&candidate_input, &frame->ch_layout);
    if (result < 0) {
        swr_free(&candidate);
        av_channel_layout_uninit(&candidate_output);
        return result;
    }

    swr_free(&owned->resampler);
    av_channel_layout_uninit(&owned->input_layout);
    av_channel_layout_uninit(&owned->output_layout);
    owned->resampler = candidate;
    owned->input_layout = candidate_input;
    owned->output_layout = candidate_output;
    owned->input_format = (enum AVSampleFormat)frame->format;
    owned->input_sample_rate = frame->sample_rate;
    owned->output_order = candidate_order;
    owned->output_mask = candidate_mask;
    return 0;
}

static int vpff_checked_output_bytes(
    int frames,
    int channels,
    size_t *byte_count
) {
    if (frames <= 0 || channels <= 0) {
        return AVERROR_INVALIDDATA;
    }
    size_t samples;
    size_t bytes;
    if (__builtin_mul_overflow((size_t)frames, (size_t)channels, &samples) ||
        __builtin_mul_overflow(samples, sizeof(float), &bytes) ||
        bytes > VPFF_MAX_AUDIO_BYTES) {
        return AVERROR(EOVERFLOW);
    }
    *byte_count = bytes;
    return 0;
}

static int vpff_emit_frame(
    VPFFAudioDecoder *owned,
    AVFrame *decoded,
    size_t *cumulative_bytes
) {
    if (decoded->sample_rate <= 0 || decoded->nb_samples <= 0 ||
        decoded->ch_layout.nb_channels <= 0 ||
        av_channel_layout_check(&decoded->ch_layout) != 1 ||
        decoded->format < 0 || decoded->opaque_ref == NULL ||
        decoded->opaque_ref->data == NULL || decoded->opaque_ref->size != sizeof(int64_t)) {
        return AVERROR_INVALIDDATA;
    }
    int64_t token = 0;
    memcpy(&token, decoded->opaque_ref->data, sizeof(token));
    if (token <= 0) {
        return AVERROR_INVALIDDATA;
    }
    int result = vpff_configure_resampler(owned, decoded);
    if (result < 0) {
        return result;
    }
    int capacity = swr_get_out_samples(owned->resampler, decoded->nb_samples);
    int channels = owned->output_layout.nb_channels;
    size_t allocation_bytes = 0;
    result = vpff_checked_output_bytes(capacity, channels, &allocation_bytes);
    if (result < 0) {
        return result;
    }
    float *output = av_malloc(allocation_bytes);
    if (output == NULL) {
        return AVERROR(ENOMEM);
    }
    uint8_t *output_planes[1] = {(uint8_t *)output};
    int converted = swr_convert(
        owned->resampler,
        output_planes,
        capacity,
        (const uint8_t *const *)decoded->extended_data,
        decoded->nb_samples
    );
    if (converted <= 0) {
        av_free(output);
        return converted < 0 ? converted : AVERROR_INVALIDDATA;
    }
    size_t exact_bytes = 0;
    result = vpff_checked_output_bytes(converted, channels, &exact_bytes);
    if (result < 0 || *cumulative_bytes > VPFF_MAX_AUDIO_BYTES - exact_bytes) {
        av_free(output);
        return result < 0 ? result : AVERROR(EOVERFLOW);
    }
    *cumulative_bytes += exact_bytes;

    VPFFPCMFrame frame = {0};
    frame.interleaved = output;
    frame.frame_count = (size_t)converted;
    frame.sample_rate = decoded->sample_rate;
    frame.channels = channels;
    frame.pts = token;
    frame.abi_version = VPFF_AUDIO_DECODER_ABI_VERSION;
    frame.struct_size = (uint32_t)sizeof(frame);
    frame.channel_order = owned->output_order;
    frame.has_channel_layout_mask = owned->output_order == VPFF_CHANNEL_ORDER_NATIVE ? 1 : 0;
    frame.channel_layout_mask = owned->output_mask;
    owned->callback(owned->callback_context, &frame);
    av_free(output);
    return 0;
}

// Audio decoders may surface codec- or platform-specific negative values for a
// malformed compressed frame. The Swift layer can safely recover from those by
// flushing and dropping a bounded number of packets, but it must still see
// allocation, state, and implementation failures unchanged.
static int vpff_normalize_packet_decode_error(int result) {
    if (result >= 0 || result == AVERROR_INVALIDDATA) {
        return result;
    }
    switch (result) {
        case AVERROR(EAGAIN):
        case AVERROR_EOF:
        case AVERROR(EINVAL):
        case AVERROR(ENOMEM):
        case AVERROR_BUG:
        case AVERROR_BUG2:
        case AVERROR_EXTERNAL:
        case AVERROR_EXIT:
        case AVERROR_UNKNOWN:
        case AVERROR_DECODER_NOT_FOUND:
        case AVERROR_PATCHWELCOME:
        case AVERROR_EXPERIMENTAL:
        case AVERROR_INPUT_CHANGED:
        case AVERROR_OUTPUT_CHANGED:
            return result;
        default:
            return AVERROR_INVALIDDATA;
    }
}

static int vpff_receive_available(
    VPFFAudioDecoder *owned,
    size_t *cumulative_bytes,
    bool *made_progress
) {
    for (;;) {
        int result = avcodec_receive_frame(owned->codec_context, owned->frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            if (result == AVERROR_EOF) {
                owned->reached_eof = true;
            }
            return result;
        }
        if (result < 0) {
            return vpff_normalize_packet_decode_error(result);
        }
        *made_progress = true;
        result = vpff_emit_frame(owned, owned->frame, cumulative_bytes);
        av_frame_unref(owned->frame);
        if (result < 0) {
            return result;
        }
    }
}

int32_t vp_ffmpeg_audio_decoder_push(
    VPFFAudioDecoder *owned,
    const uint8_t *bytes,
    size_t size,
    int64_t pts
) {
    if (owned == NULL || owned->reached_eof || pts <= 0 ||
        !vpff_valid_pointer_size(bytes, size) || size == 0 ||
        size > VPFF_MAX_AUDIO_BYTES || size > (size_t)INT_MAX) {
        return AVERROR(EINVAL);
    }

    av_packet_unref(owned->packet);
    int result = av_new_packet(owned->packet, (int)size);
    if (result < 0) {
        return result;
    }
    memcpy(owned->packet->data, bytes, size);
    owned->packet->opaque_ref = av_buffer_alloc(sizeof(int64_t));
    if (owned->packet->opaque_ref == NULL) {
        av_packet_unref(owned->packet);
        return AVERROR(ENOMEM);
    }
    memcpy(owned->packet->opaque_ref->data, &pts, sizeof(pts));
    owned->packet->pts = AV_NOPTS_VALUE;
    owned->packet->dts = AV_NOPTS_VALUE;

    size_t cumulative_bytes = 0;
    bool retried = false;
    for (;;) {
        result = avcodec_send_packet(owned->codec_context, owned->packet);
        if (result == AVERROR(EAGAIN) && !retried) {
            bool progressed = false;
            int receive_result = vpff_receive_available(
                owned,
                &cumulative_bytes,
                &progressed
            );
            if (receive_result < 0 && receive_result != AVERROR(EAGAIN)) {
                result = receive_result;
                break;
            }
            if (!progressed) {
                result = AVERROR_INVALIDDATA;
                break;
            }
            retried = true;
            continue;
        }
        break;
    }
    if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
        result = vpff_normalize_packet_decode_error(result);
    }
    if (result >= 0) {
        bool progressed = false;
        int receive_result = vpff_receive_available(owned, &cumulative_bytes, &progressed);
        if (receive_result == AVERROR(EAGAIN)) {
            result = 0;
        } else if (receive_result == AVERROR_EOF) {
            result = AVERROR_EOF;
        } else {
            result = receive_result;
        }
    }
    av_packet_unref(owned->packet);
    return result;
}

void vp_ffmpeg_audio_decoder_flush(VPFFAudioDecoder *owned) {
    if (owned == NULL) {
        return;
    }
    avcodec_flush_buffers(owned->codec_context);
    av_packet_unref(owned->packet);
    av_frame_unref(owned->frame);
    swr_free(&owned->resampler);
    av_channel_layout_uninit(&owned->input_layout);
    av_channel_layout_uninit(&owned->output_layout);
    owned->input_format = AV_SAMPLE_FMT_NONE;
    owned->input_sample_rate = 0;
    owned->output_order = VPFF_CHANNEL_ORDER_UNSPECIFIED;
    owned->output_mask = 0;
    owned->reached_eof = false;
}

void vp_ffmpeg_audio_decoder_destroy(VPFFAudioDecoder *owned) {
    if (owned == NULL) {
        return;
    }
    swr_free(&owned->resampler);
    av_channel_layout_uninit(&owned->input_layout);
    av_channel_layout_uninit(&owned->output_layout);
    av_packet_free(&owned->packet);
    av_frame_free(&owned->frame);
    avcodec_free_context(&owned->codec_context);
    free(owned);
}
