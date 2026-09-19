// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct VPFFAudioConverter VPFFAudioConverter;
// 标签编号对应 RenditionChannelLabel 的前九项；所有指针仅在同步调用内借用。
int32_t vp_ffmpeg_audio_converter_create(const uint8_t *input_labels, int32_t inputs,
    const uint8_t *output_labels, int32_t outputs, int32_t input_rate,
    const double *matrix, VPFFAudioConverter **out_converter);
int32_t vp_ffmpeg_audio_converter_capacity(VPFFAudioConverter *converter, int32_t input_frames);
int32_t vp_ffmpeg_audio_converter_convert(VPFFAudioConverter *converter,
    const float *input, int32_t frames, float *output, int32_t capacity);
void vp_ffmpeg_audio_converter_destroy(VPFFAudioConverter *converter);
