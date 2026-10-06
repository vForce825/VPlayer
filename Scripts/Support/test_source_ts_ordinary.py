#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Ordinary TS correctness checks against explicitly supplied pinned host archives.

No downloads, fixture generation, fuzzing or allocator instrumentation. This is
a host bridge check, never a substitute for the tvOS SDK/device suite.
"""
import argparse
import ctypes as c
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Diagnostic(c.Structure):
    _fields_ = [(name, c.c_int32) for name in ('stage', 'reason', 'native_result', 'container_kind',
        'input_bytes', 'usable_bytes', 'inspected_offset', 'packet_index', 'pid', 'stream_index', 'stream_count')]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg-root', type=Path, required=True)
    args = parser.parse_args()
    ffmpeg = args.ffmpeg_root.resolve()
    revision = subprocess.check_output(['git', '-C', str(ffmpeg), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == json.loads((ROOT / 'Vendor/FFmpeg/ffmpeg.lock.json').read_text())['commit']
    ordinary = load('ordinary_bridge', ROOT / 'Scripts/Support/test_source_inspector_ordinary.py')
    fixtures = load('ordinary_ts', ROOT / 'Scripts/Tests/test_native_source_admission.py')
    with tempfile.TemporaryDirectory(prefix='vplayer-ordinary-ts-bridge-') as temporary:
        directory = Path(temporary)
        (directory / 'VPlayerPlayback').symlink_to(ROOT / 'Sources/VPlayerPlayback/include', target_is_directory=True)
        wrapper = directory / 'bridge.c'
        wrapper.write_text('''#include "VPFFmpegSourceInspector.c"
int ordinary_source_read(const uint8_t *bytes,size_t size,uint8_t *out,int chunk) {
    SourceInput input={.bytes=bytes,.size=size,.deadline=INT64_MAX,.is_ts=1};
    size_t offset=0;
    while (offset<size) {
        int count=source_read(&input,out+offset,chunk);
        if (count<=0) return count;
        offset+=(size_t)count;
    }
    return (int)offset;
}
''')
        library = directory / 'bridge.so'
        command = ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unknown-pragmas',
            '-shared', '-fPIC', '-Wl,-Bsymbolic', '-I', str(directory), '-I', str(ffmpeg),
            '-I', str(ROOT / 'Sources/VPlayerPlayback/include'), '-I', str(ROOT / 'Sources/VPlayerPlayback/FFmpeg'),
            str(wrapper), str(ROOT / 'Sources/VPlayerPlayback/FFmpeg/VPSourceContainerAdmission.c'),
            str(ROOT / 'Sources/VPlayerPlayback/FFmpeg/VPSourceDolbyFramer.c'), '-Wl,--start-group']
        command += [str(ffmpeg / name / (name + '.a')) for name in ['libavformat', 'libavcodec', 'libavutil', 'libswresample']]
        command += ['-Wl,--end-group', '-lm', '-pthread', '-lz', '-latomic', '-o', str(library)]
        subprocess.run(command, check=True)
        lib = c.CDLL(str(library))
        interrupt_type = c.CFUNCTYPE(c.c_int32, c.c_void_p)
        callback_type = c.CFUNCTYPE(None, c.c_void_p, c.POINTER(ordinary.Track))
        arguments = [c.c_void_p, c.c_size_t, c.c_int32, c.c_int64, interrupt_type, callback_type, c.c_void_p, c.POINTER(c.c_int32)]
        old = lib.vp_ffmpeg_inspect_source_bytes_with_completeness
        new = lib.vp_ffmpeg_inspect_source_bytes_with_completeness_and_diagnostics
        old.argtypes, new.argtypes = arguments, arguments + [c.POINTER(Diagnostic)]
        @interrupt_type
        def running(_):
            return 0

        def inspect(data, prefix=0, enhanced=True, interrupt=running):
            facts = []
            @callback_type
            def collect(_, pointer):
                value = pointer.contents
                snapshot = {name: getattr(value, name) for name, typ in ordinary.Track._fields_ if typ != c.c_void_p}
                for name, length in [('sample', 'sample_size'), ('extradata', 'extradata_size'), ('audio_format_sample', 'audio_format_sample_size')]:
                    snapshot[name] = c.string_at(getattr(value, name), getattr(value, length)) if getattr(value, name) else b''
                facts.append(snapshot)
            buffer, kind, diagnostic = c.create_string_buffer(data), c.c_int32(), Diagnostic()
            args = [buffer, len(data), prefix, 10_000_000, interrupt, collect, None, c.byref(kind)]
            result = new(*args, c.byref(diagnostic)) if enhanced else old(*args)
            assert c.string_at(buffer, len(data)) == data, 'private read view mutated source bytes'
            if enhanced:
                assert diagnostic.native_result == result
                assert 0 <= diagnostic.stage <= 8 and 0 <= diagnostic.reason <= 13
                assert 0 <= diagnostic.input_bytes <= 8388609
                assert 0 <= diagnostic.usable_bytes <= 8388608
                assert 0 <= diagnostic.inspected_offset <= diagnostic.usable_bytes
                assert -1 <= diagnostic.packet_index <= 8388608 // 188
                assert -1 <= diagnostic.pid <= 8191 and -1 <= diagnostic.stream_index < 8
                assert 0 <= diagnostic.stream_count <= 9
            return (result, kind.value, facts), diagnostic

        data = (ROOT / 'Tests/VPlayerTests/Fixtures/Media/progressive-h264-aac.ts').read_bytes()
        control, diagnostic = inspect(data)
        assert control[0:2] == (0, 1) and diagnostic.stage == 8
        assert inspect(data, enhanced=False)[0] == control
        for packet in fixtures.ordinary_si_packets():
            for offset in [0, 188 * 30, len(data)]:
                source = data[:offset] + packet + data[offset:]
                actual, diagnostic = inspect(source)
                assert actual == control, ('complete SI changed media facts', fixtures.NativeSourceAdmissionTests.pid(packet), offset)
                assert diagnostic.inspected_offset == 0 and diagnostic.usable_bytes == len(source)
                assert inspect(source, enhanced=False)[0] == actual
        print('Complete TS: NIT/EIT/TDT beginning/middle/end preserve every scalar/header fact and old ABI')

        # Longer committed live sample ensures a repeated SPS after acquisition.
        live = (ROOT / 'Tests/VPlayerTests/Fixtures/Media/task22-progressive-h264-aac-16s.ts').read_bytes()
        prefix = live[3 * 188:3 * 188 + 1048576]
        shifted, diagnostic = inspect(prefix, prefix=1)
        assert shifted[0:2] == (0, 1) and diagnostic.inspected_offset > 32768
        assert inspect(prefix, prefix=1, enhanced=False)[0] == shifted
        assert any(track['codec'] == 1 and track['sample_size'] > 0 and track['parser_width'] == 1280 for track in shifted[2])
        assert any(track['codec'] == 3 and track['sample_rate'] == 48000 and track['channels'] == 2 for track in shifted[2])
        print('Raw prefix: late PAT acquisition remains bounded and produces H264/AAC facts')

        packets = [data[i:i + 188] for i in range(0, len(data), 188)]
        missing_pat = b''.join(packet for packet in packets if fixtures.NativeSourceAdmissionTests.pid(packet) != 0)
        failed, diagnostic = inspect(missing_pat)
        assert failed[0] < 0 and failed[2] == [] and (diagnostic.stage, diagnostic.reason) == (2, 3)
        assert inspect(missing_pat, enhanced=False)[0] == failed
        partial = data[:-188]
        failed, diagnostic = inspect(partial)
        assert failed[0] < 0 and failed[2] == [] and (diagnostic.stage, diagnostic.reason) == (3, 10)
        starts = [index for index in range(len(partial) // 188)
            if fixtures.NativeSourceAdmissionTests.pid(partial[index * 188:index * 188 + 188]) == diagnostic.pid
            and partial[index * 188 + 1] & 0x40]
        assert starts and diagnostic.packet_index == starts[-1]
        assert inspect(partial, enhanced=False)[0] == failed
        @interrupt_type
        def cancelled(_):
            return 1
        failed, diagnostic = inspect(data, interrupt=cancelled)
        assert failed[0] < 0 and failed[2] == [] and diagnostic.reason == 13
        assert inspect(data, enhanced=False, interrupt=cancelled)[0] == failed

        read = lib.ordinary_source_read
        read.argtypes = [c.c_void_p, c.c_size_t, c.c_void_p, c.c_int]
        si = fixtures.ordinary_si_packets()
        sample = si[0] + data[:376] + si[1] + data[376:752] + si[2]
        null = bytes.fromhex('47 1F FF 10') + bytes([255]) * 184
        expected = null + data[:376] + null + data[376:752] + null
        for chunk in [1, 187, 188, 189, 32768]:
            source, output = c.create_string_buffer(sample), c.create_string_buffer(len(sample))
            assert read(source, len(sample), output, chunk) == len(sample)
            assert output.raw == expected and c.string_at(source, len(sample)) == sample
        print('Private reader: no-tail path and cross-packet reads suppress only the three SI PIDs')
        print('Ordinary pinned source bridge checks PASS:', revision, 'Linux host build; no tvOS/device claim')


if __name__ == '__main__':
    main()
