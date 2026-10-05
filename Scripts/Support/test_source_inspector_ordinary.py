#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Run only committed ordinary media through an explicitly supplied bridge build.
The caller must label that library's actual FFmpeg build; this is not peak-memory
instrumentation, fixture generation or a security/fuzz corpus.
"""
import argparse
import ctypes as c
from pathlib import Path


class Track(c.Structure):
    _fields_ = [('stream_index', c.c_int32), ('media_type', c.c_int32),
                ('codec', c.c_int), ('profile', c.c_int32), ('sample_entry', c.c_uint32)]
    _fields_ += [(name, c.c_int32) for name in ('width', 'height', 'frame_rate_num', 'frame_rate_den',
        'color_primaries', 'color_transfer', 'color_matrix', 'sample_rate', 'channels')]
    _fields_ += [('channel_mask', c.c_uint64)]
    _fields_ += [(name, c.c_int32) for name in ('container_field_order', 'progressive_frames', 'interlaced_frames',
        'has_explicit_priming', 'observed_audio_packets', 'invalid_audio_timestamps')]
    _fields_ += [('leading_samples', c.c_uint32), ('trailing_samples', c.c_uint32)]
    _fields_ += [(name, c.c_int32) for name in ('audio_stream_count', 'is_default', 'is_dependent', 'is_commentary', 'has_unclassified_role')]
    _fields_ += [(name, typ) for name, typ in [('extradata', c.c_void_p), ('extradata_size', c.c_size_t),
        ('sample', c.c_void_p), ('sample_size', c.c_size_t), ('audio_format_sample', c.c_void_p), ('audio_format_sample_size', c.c_size_t)]]
    _fields_ += [(name, c.c_int32) for name in ('parser_width', 'parser_height', 'parser_color_primaries', 'parser_color_transfer', 'parser_color_matrix', 'video_timing_conflict')]


class AAC(c.Structure):
    _fields_ = [('profile', c.c_int32), ('sample_rate', c.c_int32), ('channels', c.c_int32), ('channel_mask', c.c_uint64)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True)
    parser.add_argument('--ffmpeg-label', required=True)
    args = parser.parse_args()
    print('Runtime label supplied by caller:', args.ffmpeg_label)
    lib = c.CDLL(args.library)
    interrupt_type = c.CFUNCTYPE(c.c_int32, c.c_void_p)
    callback_type = c.CFUNCTYPE(None, c.c_void_p, c.POINTER(Track))
    inspect = lib.vp_ffmpeg_inspect_source_bytes_with_completeness
    inspect.argtypes = [c.c_void_p, c.c_size_t, c.c_int32, c.c_int64, interrupt_type, callback_type, c.c_void_p, c.POINTER(c.c_int32)]
    observe_aac = lib.vp_ffmpeg_inspect_adts_format
    observe_aac.argtypes = [c.c_void_p, c.c_size_t, c.c_int64, interrupt_type, c.c_void_p, c.POINTER(AAC)]

    @interrupt_type
    def running(_):
        return 0

    root = Path(__file__).resolve().parents[2] / 'Tests/VPlayerTests/Fixtures/Media'
    cases = [('progressive-h264-aac.ts', 0, None), ('ac3-48k-5point1.mov', 0, None)]
    live = root / 'task22-progressive-h264-aac-16s.ts'
    if live.exists():
        cases += [(live.name, 1, 1_048_576), (live.name, 0, 1_048_576)]
    for name, prefix, count in cases:
        data = (root / name).read_bytes()
        if count is not None:
            assert len(data) > count
            data = data[:count]
        observed = []

        @callback_type
        def collect(_, pointer):
            item = pointer.contents
            scalar = {field: getattr(item, field) for field in (
                'codec', 'width', 'height', 'parser_width', 'parser_height',
                'frame_rate_num', 'frame_rate_den', 'parser_color_primaries', 'parser_color_transfer',
                'parser_color_matrix', 'sample_rate', 'channels', 'profile', 'sample_size',
                'observed_audio_packets', 'invalid_audio_timestamps')}
            scalar['format_bytes'] = c.string_at(item.audio_format_sample, item.audio_format_sample_size) if item.audio_format_sample else b''
            observed.append(scalar)

        buffer = c.create_string_buffer(data)
        kind = c.c_int32()
        result = inspect(buffer, len(data), prefix, 10_000_000, running, collect, None, c.byref(kind))
        print(name, 'prefix', prefix, 'bytes', len(data), 'result', result, 'container', kind.value)
        if count is not None and not prefix:
            assert result < 0 and not observed
            continue
        assert result == 0 and observed
        for track in observed:
            compressed = track.pop('format_bytes')
            print('  facts', track)
            if track['codec'] == 1:
                assert track['parser_width'] > 0 and track['parser_height'] > 0
                assert track['frame_rate_num'] > 0 and track['frame_rate_den'] > 0
                assert track['sample_size'] < 256 * 1024
            if compressed:
                form = AAC()
                data_buffer = c.create_string_buffer(compressed)
                status = observe_aac(data_buffer, len(compressed), 500_000, running, None, c.byref(form))
                print('  AAC phase', status, form.profile, form.sample_rate, form.channels, hex(form.channel_mask), 'input', len(compressed))
                assert status == 0 and form.profile == 1 and form.sample_rate == 48000 and form.channels == 2 and form.channel_mask == 3
    print('Ordinary committed-media bridge checks PASS')


if __name__ == '__main__':
    main()
