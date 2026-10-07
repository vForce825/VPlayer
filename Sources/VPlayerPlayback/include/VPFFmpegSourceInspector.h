// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <VPlayerPlayback/VPFFmpegDemuxer.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t stream_index, media_type;
    VPFFCodec codec;
    int32_t profile;
    uint32_t sample_entry;
    int32_t width, height; /* Immutable container dimensions; 0 unavailable. */
    int32_t frame_rate_num, frame_rate_den; /* Explicit codec or stable packet timing. */
    int32_t color_primaries, color_transfer, color_matrix; /* ISO 2 absent; 0 is present. */
    int32_t sample_rate, channels;
    uint64_t channel_mask;
    int32_t container_field_order;
    int32_t progressive_frames, interlaced_frames;
    int32_t has_explicit_priming;
    int32_t observed_audio_packets, invalid_audio_timestamps;
    uint32_t leading_samples, trailing_samples;
    int32_t audio_stream_count, is_default, is_dependent, is_commentary, has_unclassified_role;
    const uint8_t *extradata;
    size_t extradata_size;
    const uint8_t *sample;
    size_t sample_size;
    const uint8_t *audio_format_sample;
    size_t audio_format_sample_size;
    int32_t parser_width, parser_height;
    int32_t parser_color_primaries, parser_color_transfer, parser_color_matrix;
    int32_t video_timing_conflict;
} VPFFSourceTrack;
typedef void (*VPFFSourceTrackCallback)(void *, const VPFFSourceTrack *);
typedef int32_t (*VPFFSourceInterrupt)(void *);
enum {
    VPFF_SOURCE_ACQUISITION_READY=0, VPFF_SOURCE_ACQUISITION_NEEDS_MORE=1,
    VPFF_SOURCE_ACQUISITION_STOP=2, VPFF_SOURCE_ACQUISITION_CANCELLED=3
};
/* Allocation-free TS prefix hint, <=8 MiB borrowed input. READY only reports
 * complete candidate parameter NALs in the admitted native byte view; it is
 * never codec/format proof. NEEDS_MORE is limited to missing tables, acquisition
 * or eligible video headers. Audio-only and unsupported video return STOP. */
int32_t vp_ffmpeg_source_ts_acquisition_hint(const uint8_t *,size_t,VPFFSourceInterrupt,void *);
enum {
    VPFF_SOURCE_STAGE_NONE=0, VPFF_SOURCE_STAGE_ARGUMENT=1, VPFF_SOURCE_STAGE_CONTAINER=2,
    VPFF_SOURCE_STAGE_PES_TAIL=3, VPFF_SOURCE_STAGE_DEMUX_OPEN=4, VPFF_SOURCE_STAGE_TRACK=5,
    VPFF_SOURCE_STAGE_PACKET=6, VPFF_SOURCE_STAGE_FINAL=7, VPFF_SOURCE_STAGE_COMPLETE=8
};
enum {
    VPFF_SOURCE_REASON_NONE=0, VPFF_SOURCE_REASON_INVALID_ARGUMENT=1, VPFF_SOURCE_REASON_STRUCTURE=2,
    VPFF_SOURCE_REASON_MISSING_PAT=3, VPFF_SOURCE_REASON_MISSING_PMT=4,
    VPFF_SOURCE_REASON_CHANGED_PAT=5, VPFF_SOURCE_REASON_CHANGED_PMT=6,
    VPFF_SOURCE_REASON_TOPOLOGY=7, VPFF_SOURCE_REASON_UNKNOWN_PID=8,
    VPFF_SOURCE_REASON_ACQUISITION=9, VPFF_SOURCE_REASON_PES_TAIL=10,
    VPFF_SOURCE_REASON_NATIVE=11, VPFF_SOURCE_REASON_LIMIT=12, VPFF_SOURCE_REASON_CANCELLED=13
};
/* Per-call scalar evidence only; no strings, pointers or global error state.
 * Indices/PID are -1 when unavailable. Byte fields are <=8 MiB, except the
 * input_bytes over-limit sentinel of 8 MiB+1. inspected_offset and packet_index
 * use original-input byte/TS-packet coordinates. Does not change the return value. */
typedef struct {
    int32_t stage, reason, native_result, container_kind;
    int32_t input_bytes, usable_bytes, inspected_offset;
    int32_t packet_index, pid, stream_index, stream_count;
} VPFFSourceDiagnostic;
/* Synchronous byte-fed call: no child I/O, broad stream-info or video decode.
 * Callback pointers are borrowed only until return. Cancellation joins cleanup. */
int32_t vp_ffmpeg_inspect_source_bytes(const uint8_t *,size_t,int64_t,
    VPFFSourceInterrupt,VPFFSourceTrackCallback,void *,int32_t *);
int32_t vp_ffmpeg_inspect_source_bytes_with_completeness(const uint8_t *,size_t,int32_t,int64_t,
    VPFFSourceInterrupt,VPFFSourceTrackCallback,void *,int32_t *);
int32_t vp_ffmpeg_inspect_source_bytes_with_completeness_and_diagnostics(const uint8_t *,size_t,int32_t,int64_t,
    VPFFSourceInterrupt,VPFFSourceTrackCallback,void *,int32_t *,VPFFSourceDiagnostic *);
typedef struct { int32_t profile,sample_rate,channels; uint64_t channel_mask; } VPFFSourceAACFormat;
/* Separate, sequential AAC-only factual phase after all container/BSF/AVC
 * workspace has closed. <=8 AUs/64KiB, <=500ms, gated output <=1MiB. */
int32_t vp_ffmpeg_inspect_adts_format(const uint8_t *,size_t,int64_t,
    VPFFSourceInterrupt,void *,VPFFSourceAACFormat *);
#ifdef __cplusplus
}
#endif
