// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegAudioConverter.h"
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#pragma clang diagnostic pop

struct VPFFAudioConverter {
    SwrContext *swr;
    int inputs, outputs, rate;
    int input_order[8], output_order[8];
};

static int layout(const uint8_t *labels, int count, AVChannelLayout *value, int *order) {
    static const int bits[9] = {0,1,2,3,9,10,8,4,5};
    uint64_t mask = 0;
    if (!labels || count < 1 || count > 8) return -EINVAL;
    for (int i = 0; i < count; ++i) {
        if (labels[i] > 8 || (mask & (UINT64_C(1) << bits[labels[i]]))) return -EINVAL;
        mask |= UINT64_C(1) << bits[labels[i]];
    }
    int result = av_channel_layout_from_mask(value, mask);
    if (result < 0) return result;
    for (int i = 0; i < count; ++i) {
        order[i] = av_channel_layout_index_from_channel(value, (enum AVChannel)bits[labels[i]]);
    }
    return 0;
}

int32_t vp_ffmpeg_audio_converter_create(const uint8_t *input_labels, int32_t inputs,
    const uint8_t *output_labels, int32_t outputs, int32_t input_rate,
    const double *matrix, VPFFAudioConverter **out_converter) {
    if (!out_converter) return -EINVAL;
    *out_converter = NULL;
    if (!matrix || input_rate < 1 || input_rate > 0xFFFFFF) return -EINVAL;
    VPFFAudioConverter *owned = calloc(1, sizeof(*owned));
    if (!owned) return -ENOMEM;
    AVChannelLayout in = {0}, out = {0};
    int result = layout(input_labels, inputs, &in, owned->input_order);
    if (result >= 0) result = layout(output_labels, outputs, &out, owned->output_order);
    double reordered[64] = {0};
    if (result >= 0) {
        for (int row = 0; row < outputs; ++row) for (int col = 0; col < inputs; ++col) {
            double coefficient = matrix[row * inputs + col];
            if (!isfinite(coefficient) || fabs(coefficient) > 1) { result = -EINVAL; break; }
            reordered[owned->output_order[row] * inputs + owned->input_order[col]] = coefficient;
        }
    }
    if (result >= 0) result = swr_alloc_set_opts2(&owned->swr, &out, AV_SAMPLE_FMT_DBL, 48000,
        &in, AV_SAMPLE_FMT_FLT, input_rate, 0, NULL);
    if (result >= 0) result = av_opt_set_sample_fmt(owned->swr, "internal_sample_fmt", AV_SAMPLE_FMT_DBLP, 0);
    if (result >= 0) result = swr_set_matrix(owned->swr, reordered, inputs);
    if (result >= 0) result = swr_init(owned->swr);
    av_channel_layout_uninit(&in); av_channel_layout_uninit(&out);
    if (result < 0) { vp_ffmpeg_audio_converter_destroy(owned); return result; }
    owned->inputs = inputs; owned->outputs = outputs; owned->rate = input_rate;
    *out_converter = owned;
    return 0;
}

int32_t vp_ffmpeg_audio_converter_capacity(VPFFAudioConverter *owned, int32_t frames) {
    if (!owned || frames < 0 || frames > 16384) return -EINVAL;
    int64_t delay = swr_get_delay(owned->swr, owned->rate);
    if (delay < 0 || delay > 262144) return -EOVERFLOW;
    int64_t capacity = av_rescale_rnd(delay + frames, 48000, owned->rate, AV_ROUND_UP);
    if (capacity > 131072) return -EOVERFLOW;
    return (int32_t)(capacity > 0 ? capacity : 1);
}

int32_t vp_ffmpeg_audio_converter_convert(VPFFAudioConverter *owned,
    const float *input, int32_t frames, float *output, int32_t capacity) {
    if (!owned || !output || frames < 0 || frames > 16384 || capacity < 1 || capacity > 131072 ||
        (frames > 0 && !input)) return -EINVAL;
    float *reordered = frames ? malloc((size_t)frames * owned->inputs * sizeof(float)) : NULL;
    double *converted = malloc((size_t)capacity * owned->outputs * sizeof(double));
    if ((frames && !reordered) || !converted) { free(reordered); free(converted); return -ENOMEM; }
    for (int frame = 0; frame < frames; ++frame) for (int ch = 0; ch < owned->inputs; ++ch) {
        float value = input[frame * owned->inputs + ch];
        if (!isfinite(value) || fabsf(value) > 1) { free(reordered); free(converted); return -EINVAL; }
        reordered[frame * owned->inputs + owned->input_order[ch]] = value;
    }
    const uint8_t *in[] = {(const uint8_t *)reordered};
    uint8_t *out[] = {(uint8_t *)converted};
    int result = swr_convert(owned->swr, out, capacity, frames ? in : NULL, frames);
    for (int frame = 0; frame < result; ++frame) for (int ch = 0; ch < owned->outputs; ++ch) {
        double value = converted[frame * owned->outputs + owned->output_order[ch]];
        // 不允许 limiter 或 clamp；超出可表示的安全幅度时终止该输出。
        if (!isfinite(value) || fabs(value) > 1.0000000000000002) { result = -ERANGE; break; }
        output[frame * owned->outputs + ch] = (float)value;
    }
    free(reordered); free(converted);
    return result;
}

void vp_ffmpeg_audio_converter_destroy(VPFFAudioConverter *owned) {
    if (!owned) return;
    swr_free(&owned->swr);
    free(owned);
}
