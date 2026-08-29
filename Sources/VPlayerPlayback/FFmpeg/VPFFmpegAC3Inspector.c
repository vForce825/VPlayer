// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <VPlayerPlayback/VPFFmpegAC3Inspector.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/ac3_parser.h>
#include <libavutil/crc.h>
#pragma clang diagnostic pop

#include <string.h>

typedef struct {
    const uint8_t *bytes;
    size_t bit_count;
    size_t bit_offset;
} VPFFAC3BitReader;

static int vp_ffmpeg_ac3_read_bits(
    VPFFAC3BitReader *reader,
    uint8_t count,
    uint32_t *out_value
) {
    if (!reader || !out_value || count > 32 ||
        reader->bit_offset > reader->bit_count ||
        (size_t)count > reader->bit_count - reader->bit_offset) {
        return -1;
    }
    uint32_t value = 0;
    for (uint8_t index = 0; index < count; index++) {
        const size_t offset = reader->bit_offset++;
        const uint8_t byte = reader->bytes[offset / 8];
        value = (value << 1) | ((byte >> (7 - offset % 8)) & 1);
    }
    *out_value = value;
    return 0;
}

int32_t vp_ffmpeg_inspect_ac3_frame_v1(
    const uint8_t *bytes,
    size_t size,
    VPFFAC3FrameInfoV1 *out_info
) {
    if (!bytes || !out_info || size < 7) {
        return -1;
    }

    uint8_t parsed_bsid = 0;
    uint16_t parsed_frame_size = 0;
    if (av_ac3_parse_header(
            bytes, size, &parsed_bsid, &parsed_frame_size
        ) < 0 || parsed_bsid > 10 || size != parsed_frame_size) {
        return -1;
    }

    VPFFAC3BitReader reader = {
        .bytes = bytes,
        .bit_count = size * 8,
        .bit_offset = 0,
    };
    uint32_t syncword = 0;
    uint32_t crc1 = 0;
    uint32_t fscod = 0;
    uint32_t frmsizecod = 0;
    uint32_t bsid = 0;
    uint32_t bsmod = 0;
    uint32_t acmod = 0;
    uint32_t lfeon = 0;
    uint32_t ignored = 0;
    if (vp_ffmpeg_ac3_read_bits(&reader, 16, &syncword) < 0 || syncword != 0x0B77 ||
        vp_ffmpeg_ac3_read_bits(&reader, 16, &crc1) < 0 ||
        vp_ffmpeg_ac3_read_bits(&reader, 2, &fscod) < 0 || fscod > 2 ||
        vp_ffmpeg_ac3_read_bits(&reader, 6, &frmsizecod) < 0 || frmsizecod > 37 ||
        vp_ffmpeg_ac3_read_bits(&reader, 5, &bsid) < 0 ||
        bsid != parsed_bsid || bsid > 10 ||
        vp_ffmpeg_ac3_read_bits(&reader, 3, &bsmod) < 0 ||
        vp_ffmpeg_ac3_read_bits(&reader, 3, &acmod) < 0) {
        return -1;
    }
    if ((acmod & 1) != 0 && acmod != 1 &&
        vp_ffmpeg_ac3_read_bits(&reader, 2, &ignored) < 0) {
        return -1;
    }
    if ((acmod & 4) != 0 && vp_ffmpeg_ac3_read_bits(&reader, 2, &ignored) < 0) {
        return -1;
    }
    if (acmod == 2 && vp_ffmpeg_ac3_read_bits(&reader, 2, &ignored) < 0) {
        return -1;
    }
    if (vp_ffmpeg_ac3_read_bits(&reader, 1, &lfeon) < 0) {
        return -1;
    }

    const AVCRC *crc_table = av_crc_get_table(AV_CRC_16_ANSI);
    if (!crc_table ||
        av_crc(crc_table, 0, bytes + 2, parsed_frame_size - 2) != 0) {
        return -1;
    }

    static const int32_t sample_rates[3] = {48000, 44100, 32000};
    static const int32_t base_channels[8] = {2, 1, 2, 3, 3, 4, 4, 5};
    const uint32_t sample_rate_shift = bsid > 8 ? bsid - 8 : 0;

    VPFFAC3FrameInfoV1 result;
    memset(&result, 0, sizeof(result));
    result.abi_version = VPFF_AC3_INSPECTOR_ABI_VERSION;
    result.struct_size = (uint32_t)sizeof(result);
    result.frame_size = parsed_frame_size;
    result.sample_rate = sample_rates[fscod] >> sample_rate_shift;
    result.sample_count = 1536;
    result.channel_count = base_channels[acmod] + (int32_t)lfeon;
    result.fscod = (uint8_t)fscod;
    result.bsid = (uint8_t)bsid;
    result.bsmod = (uint8_t)bsmod;
    result.acmod = (uint8_t)acmod;
    result.lfeon = (uint8_t)lfeon;
    result.frmsizecod = (uint8_t)frmsizecod;
    *out_info = result;
    return 0;
}
