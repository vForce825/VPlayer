// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegVideoDecoder.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#pragma clang diagnostic pop

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define VPFF_HAS_NEON 1
#endif

struct VPFFVideoDecoder {
    AVCodecContext *codec_context;
    AVPacket *packet;
    AVFrame *frame;
    VPFFVideoFrameCallback callback;
    void *context;
};

static int32_t deliver_frame(VPFFVideoDecoder *decoder, const AVFrame *frame) {
    // Only the one planar layout this pipeline can turn into NV12. A decoder
    // that produced anything else would otherwise be read as 4:2:0 and torn.
    if (frame->format != AV_PIX_FMT_YUV420P) {
        return VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT;
    }
    if (frame->data[0] == NULL || frame->data[1] == NULL || frame->data[2] == NULL ||
        frame->width <= 0 || frame->height <= 0 ||
        (frame->width & 1) != 0 || (frame->height & 1) != 0) {
        return VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT;
    }
    const int32_t chroma_width = frame->width / 2;
    if (frame->linesize[0] <= 0 || frame->linesize[1] <= 0 || frame->linesize[2] <= 0 ||
        frame->linesize[0] < frame->width ||
        frame->linesize[1] < chroma_width || frame->linesize[2] < chroma_width) {
        return VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT;
    }

    VPFFVideoRange range = VPFF_VIDEO_RANGE_UNKNOWN;
    if (frame->color_range == AVCOL_RANGE_MPEG) {
        range = VPFF_VIDEO_RANGE_VIDEO;
    } else if (frame->color_range == AVCOL_RANGE_JPEG) {
        range = VPFF_VIDEO_RANGE_FULL;
    }

    VPFFVideoFrame delivered = {
        .luma = frame->data[0],
        .chroma_b = frame->data[1],
        .chroma_r = frame->data[2],
        .luma_stride = frame->linesize[0],
        .chroma_b_stride = frame->linesize[1],
        .chroma_r_stride = frame->linesize[2],
        .width = frame->width,
        .height = frame->height,
        .pts = frame->pts,
        .abi_version = VPFF_VIDEO_DECODER_ABI_VERSION,
        .struct_size = (uint32_t)sizeof(VPFFVideoFrame),
        .is_interlaced = (frame->flags & AV_FRAME_FLAG_INTERLACED) != 0 ? 1 : 0,
        .top_field_first = (frame->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0 ? 1 : 0,
        .reserved = {0, 0},
        .range = range,
        .color_primaries = (int32_t)frame->color_primaries,
        .color_transfer = (int32_t)frame->color_trc,
        .color_matrix = (int32_t)frame->colorspace,
    };
    decoder->callback(decoder->context, &delivered);
    return 0;
}

static int32_t deliver(VPFFVideoDecoder *decoder) {
    return deliver_frame(decoder, decoder->frame);
}

#if DEBUG
int32_t vp_ffmpeg_video_decoder_debug_deliver_synthetic_frame(
    int32_t format,
    const uint8_t *luma,
    int32_t luma_stride,
    const uint8_t *chroma_b,
    int32_t chroma_b_stride,
    const uint8_t *chroma_r,
    int32_t chroma_r_stride,
    int32_t width,
    int32_t height,
    VPFFVideoFrameCallback callback,
    void *context
);

int32_t vp_ffmpeg_video_decoder_debug_deliver_synthetic_frame(
    int32_t format,
    const uint8_t *luma,
    int32_t luma_stride,
    const uint8_t *chroma_b,
    int32_t chroma_b_stride,
    const uint8_t *chroma_r,
    int32_t chroma_r_stride,
    int32_t width,
    int32_t height,
    VPFFVideoFrameCallback callback,
    void *context
) {
    AVFrame frame = {0};
    frame.format = format;
    frame.data[0] = (uint8_t *)luma;
    frame.data[1] = (uint8_t *)chroma_b;
    frame.data[2] = (uint8_t *)chroma_r;
    frame.linesize[0] = luma_stride;
    frame.linesize[1] = chroma_b_stride;
    frame.linesize[2] = chroma_r_stride;
    frame.width = width;
    frame.height = height;

    VPFFVideoDecoder decoder = {
        .callback = callback,
        .context = context,
    };
    return deliver_frame(&decoder, &frame);
}
#endif

static int32_t drain(
    VPFFVideoDecoder *decoder,
    int64_t *out_failure_token,
    uint8_t *out_has_failure_token
) {
    for (;;) {
        int result = avcodec_receive_frame(decoder->codec_context, decoder->frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return 0;
        }
        if (result < 0) {
            return (int32_t)result;
        }
        const int64_t frame_pts = decoder->frame->pts;
        int32_t delivery_result = deliver(decoder);
        av_frame_unref(decoder->frame);
        if (delivery_result != 0) {
            if (frame_pts > 0 && frame_pts != AV_NOPTS_VALUE) {
                *out_failure_token = frame_pts;
                *out_has_failure_token = 1;
            }
            return delivery_result;
        }
    }
}

int32_t vp_ffmpeg_video_decoder_create(
    const uint8_t *extradata,
    size_t extradata_size,
    int32_t thread_count,
    VPFFVideoFrameCallback callback,
    void *context,
    VPFFVideoDecoder **out_decoder
) {
    if (out_decoder == NULL || callback == NULL) {
        return AVERROR(EINVAL);
    }
    if (extradata_size > 0 && extradata == NULL) {
        return AVERROR(EINVAL);
    }
    if (extradata_size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) {
        return AVERROR(EINVAL);
    }
    *out_decoder = NULL;

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (codec == NULL) {
        return AVERROR_DECODER_NOT_FOUND;
    }

    VPFFVideoDecoder *owned = calloc(1, sizeof(VPFFVideoDecoder));
    if (owned == NULL) {
        return AVERROR(ENOMEM);
    }
    owned->callback = callback;
    owned->context = context;
    owned->codec_context = avcodec_alloc_context3(codec);
    owned->packet = av_packet_alloc();
    owned->frame = av_frame_alloc();
    if (owned->codec_context == NULL || owned->packet == NULL || owned->frame == NULL) {
        vp_ffmpeg_video_decoder_destroy(owned);
        return AVERROR(ENOMEM);
    }

    if (extradata_size > 0) {
        owned->codec_context->extradata =
            av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (owned->codec_context->extradata == NULL) {
            vp_ffmpeg_video_decoder_destroy(owned);
            return AVERROR(ENOMEM);
        }
        memcpy(owned->codec_context->extradata, extradata, extradata_size);
        owned->codec_context->extradata_size = (int)extradata_size;
    }

    // Frame threading is what makes this worth doing: field-coded H.264 does not
    // slice well, but successive frames pipeline across cores.
    owned->codec_context->thread_count = thread_count > 0 ? thread_count : 0;
    owned->codec_context->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    owned->codec_context->flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT;
    owned->codec_context->flags2 |= AV_CODEC_FLAG2_SHOW_ALL;

    int result = avcodec_open2(owned->codec_context, codec, NULL);
    if (result < 0) {
        vp_ffmpeg_video_decoder_destroy(owned);
        return (int32_t)result;
    }
    *out_decoder = owned;
    return 0;
}

int32_t vp_ffmpeg_video_decoder_push(
    VPFFVideoDecoder *decoder,
    const uint8_t *bytes,
    size_t size,
    int64_t pts,
    int64_t *out_failure_token,
    uint8_t *out_has_failure_token
) {
    if (out_failure_token != NULL) {
        *out_failure_token = 0;
    }
    if (out_has_failure_token != NULL) {
        *out_has_failure_token = 0;
    }
    if (out_failure_token == NULL || out_has_failure_token == NULL) {
        return AVERROR(EINVAL);
    }
    if (decoder == NULL) {
        return AVERROR(EINVAL);
    }
    if (size > 0 && bytes == NULL) {
        return AVERROR(EINVAL);
    }
    if (size > INT_MAX) {
        return AVERROR(EINVAL);
    }

    av_packet_unref(decoder->packet);
    if (size > 0) {
        int result = av_new_packet(decoder->packet, (int)size);
        if (result < 0) {
            return (int32_t)result;
        }
        memcpy(decoder->packet->data, bytes, size);
    }
    decoder->packet->pts = pts;
    decoder->packet->dts = pts;

    int result = avcodec_send_packet(
        decoder->codec_context,
        size > 0 ? decoder->packet : NULL
    );
    av_packet_unref(decoder->packet);
    // A frame the decoder cannot use is not a session failure: the reference it
    // wanted was dropped upstream, and the next random-access unit recovers.
    if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_INVALIDDATA) {
        return (int32_t)result;
    }
    return drain(decoder, out_failure_token, out_has_failure_token);
}

void vp_ffmpeg_video_write_biplanar(
    const uint8_t *luma, int32_t luma_stride,
    const uint8_t *chroma_b, int32_t chroma_b_stride,
    const uint8_t *chroma_r, int32_t chroma_r_stride,
    uint8_t *destination_luma, size_t destination_luma_stride,
    uint8_t *destination_chroma, size_t destination_chroma_stride,
    int32_t width, int32_t height
) {
    if (luma == NULL || chroma_b == NULL || chroma_r == NULL ||
        destination_luma == NULL || destination_chroma == NULL ||
        width <= 0 || height <= 0) {
        return;
    }

    for (int32_t row = 0; row < height; ++row) {
        memcpy(
            destination_luma + (size_t)row * destination_luma_stride,
            luma + (size_t)row * luma_stride,
            (size_t)width
        );
    }

    const int32_t chroma_width = width / 2;
    const int32_t chroma_height = height / 2;
    for (int32_t row = 0; row < chroma_height; ++row) {
        const uint8_t *source_b = chroma_b + (size_t)row * chroma_b_stride;
        const uint8_t *source_r = chroma_r + (size_t)row * chroma_r_stride;
        uint8_t *destination = destination_chroma + (size_t)row * destination_chroma_stride;
        int32_t column = 0;
#if defined(VPFF_HAS_NEON)
        // One store lays down sixteen Cb/Cr pairs already interleaved.
        for (; column + 16 <= chroma_width; column += 16) {
            uint8x16x2_t pair;
            pair.val[0] = vld1q_u8(source_b + column);
            pair.val[1] = vld1q_u8(source_r + column);
            vst2q_u8(destination + (size_t)column * 2, pair);
        }
#endif
        for (; column < chroma_width; ++column) {
            destination[(size_t)column * 2] = source_b[column];
            destination[(size_t)column * 2 + 1] = source_r[column];
        }
    }
}

void vp_ffmpeg_video_decoder_flush(VPFFVideoDecoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    avcodec_flush_buffers(decoder->codec_context);
    av_packet_unref(decoder->packet);
    av_frame_unref(decoder->frame);
}

void vp_ffmpeg_video_decoder_destroy(VPFFVideoDecoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->codec_context != NULL) {
        avcodec_free_context(&decoder->codec_context);
    }
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->frame);
    free(decoder);
}
