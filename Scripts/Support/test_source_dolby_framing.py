#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Ordinary frame-boundary checks against the production fixed-buffer framer.
Pass an explicit built library. This does not generate a fixture or run a corpus.
"""
import argparse
import ctypes as c
from pathlib import Path


class Info(c.Structure):
    _fields_ = [(name, c.c_int) for name in (
        'frame_size', 'sample_rate', 'sample_count', 'channels', 'bsid',
        'stream_type', 'substream_id', 'bsmod')]


class Framer(c.Structure):
    _fields_ = [('bytes', c.c_uint8 * 4160), ('pending_size', c.c_size_t),
                ('expected_size', c.c_size_t), ('enhanced', c.c_int),
                ('crossed_input', c.c_int), ('info', Info)]


def frames(root):
    mov = (root / 'ac3-48k-5point1.mov').read_bytes()
    offset = 0
    while offset + 8 <= len(mov):
        size = int.from_bytes(mov[offset:offset+4], 'big')
        assert 8 <= size <= len(mov)-offset
        if mov[offset+4:offset+8] == b'mdat':
            ac3 = mov[offset+8:offset+8+1792]
            break
        offset += size
    else:
        raise AssertionError('ordinary AC-3 fixture has no media body')
    eac3 = (root / 'eac3-main-6x1block-5.1.eac3').read_bytes()
    length = 2 * (((eac3[2] & 7) << 8 | eac3[3]) + 1)
    return [(False, ac3), (True, eac3[:length])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True)
    args = parser.parse_args()
    lib = c.CDLL(args.library)
    callback_type = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p, c.c_size_t,
                               c.POINTER(Info), c.c_size_t)
    lib.vp_source_dolby_init.argtypes = [c.POINTER(Framer), c.c_int]
    lib.vp_source_dolby_append.argtypes = [c.POINTER(Framer), c.c_void_p, c.c_size_t, callback_type, c.c_void_p]
    lib.vp_source_dolby_finish.argtypes = [c.POINTER(Framer), c.c_int]
    root = Path(__file__).resolve().parents[2] / 'Tests/VPlayerTests/Fixtures/Media'
    for enhanced, frame in frames(root):
        for split in [None, 1, 3, 7, len(frame)-1]:
            state = Framer()
            lib.vp_source_dolby_init(c.byref(state), enhanced)
            observed = []

            @callback_type
            def collect(_, data, size, info, start):
                observed.append((c.string_at(data, size), info.contents.sample_count, start))
                return 0

            chunks = [frame * 3] if split is None else [frame[:split], frame[split:] + frame]
            for chunk in chunks:
                buffer = c.create_string_buffer(chunk)
                assert lib.vp_source_dolby_append(c.byref(state), buffer, len(chunk), collect, None) == 0
            assert lib.vp_source_dolby_finish(c.byref(state), 1) == 0
            assert [x[0] for x in observed] == [frame] * (3 if split is None else 2)
            assert all(x[1] == (256 if enhanced else 1536) for x in observed)
            if split is not None:
                assert observed[0][2] == c.c_size_t(-1).value
        state = Framer()
        lib.vp_source_dolby_init(c.byref(state), enhanced)
        chunk = frame[:-1]
        buffer = c.create_string_buffer(chunk)
        assert lib.vp_source_dolby_append(c.byref(state), buffer, len(chunk), collect, None) == 0
        assert lib.vp_source_dolby_finish(c.byref(state), 0) == 0
        assert lib.vp_source_dolby_finish(c.byref(state), 1) < 0
        print(('E-AC-3' if enhanced else 'AC-3') + ': grouped/boundary/finite-tail ordinary checks PASS')


if __name__ == '__main__':
    main()
