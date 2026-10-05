#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise ordinary source metadata with the real, dependency-free C parser.

The complete 706-byte initialization below came from AVAssetWriter in
HLSManagedDemuxSmokeTests on 2026-10-05, using the committed synthetic
task22-progressive-h264-aac-16s.ts fixture. It includes CoreMedia's two-byte
chrm extension. This metadata-only unit test does not pretend that an init
segment, or the truncated media prefix from the CI log, is a complete movie.
The managed smoke test separately exercises admission of the original complete
native initialization plus media and the pinned FFmpeg reader.
"""
import base64
import ctypes
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE_INITIALIZATION = base64.b64decode(
    'AAAAHGZ0eXBpc281AAAAAWlzb21pc281aGxzZgAAAqZtb292AAAAbG12aGQAAAAA5umzrebps60AAAJYAAAAAAAB'
    'AAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAACAAACCnRyYWsAAABcdGtoZAAAAAHm6bOt5umzrQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAFAAAAAtAAAAAAAaZtZGlhAAAAIG1kaGQAAAAA'
    '5umzrebps60ACvyAAAAAAFXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVkaWEgVmlk'
    'ZW8AAAABTW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAA'
    'AQAAAQ1zdGJsAAAAwXN0c2QAAAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAABQAC0ABIAAAA'
    'SAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAf/+EAGmdkAB+s'
    '2UBQBbsBEAAAAwAQAAADAyDxgxlgAQAGaOvjyyLA/fj4AAAAAApmaWVsAQAAAAAKY2hybQAAAAAAEHBhc3AAAAAB'
    'AAAAAQAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAA'
    'AAAAAAAAAAAAKG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAA=='
)


class NativeSourceAdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='vplayer-source-admission-')
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        wrapper = directory / 'metadata.c'
        wrapper.write_text('''#include "VPSourceContainerAdmission.c"
int inspect_native_initialization(const uint8_t *bytes, size_t size) {
    Admission admission = {0};
    int result = boxes(&admission, bytes, size, 0, 0);
    if (result < 0) return result;
    return admission.moov && admission.mvex && admission.tracks == 1 &&
           admission.video == 1 && !admission.mdat && !admission.moofs ? 0 : -EINVAL;
}
''')
        library = directory / 'admission.so'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC',
                        '-I', str(ROOT / 'Sources/VPlayerPlayback/FFmpeg'),
                        str(wrapper), '-o', str(library)], check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.initialization = cls.library.inspect_native_initialization
        cls.initialization.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        cls.initialization.restype = ctypes.c_int
        cls.admit = cls.library.vp_source_admit_container
        cls.admit.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                             ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_size_t)]
        cls.admit.restype = ctypes.c_int

    def test_complete_native_initialization_accepts_chroma_location_extension(self):
        # Removing chrm support must fail this exact native metadata traversal.
        self.assertEqual(len(NATIVE_INITIALIZATION), 706)
        self.assertEqual(NATIVE_INITIALIZATION[572:582], b'\x00\x00\x00\x0achrm\x00\x00')
        buffer = ctypes.create_string_buffer(NATIVE_INITIALIZATION)
        self.assertEqual(self.initialization(buffer, len(NATIVE_INITIALIZATION)), 0)

    def test_complete_committed_ordinary_containers_keep_their_classification(self):
        media = ROOT / 'Tests/VPlayerTests/Fixtures/Media'
        source = ROOT / 'Tests/Fixtures/SourcePlanning'
        cases = [
            ('mpeg-ts', (media / 'progressive-h264-aac.ts').read_bytes(), 1),
            ('quicktime', (media / 'ac3-48k-5point1.mov').read_bytes(), 3),
            ('fragmented-mp4', (source / 'progressive-init.mp4').read_bytes() +
             (source / 'progressive-0.m4s').read_bytes(), 2),
        ]
        for name, data, expected in cases:
            with self.subTest(container=name):
                buffer = ctypes.create_string_buffer(data)
                kind = ctypes.c_int32()
                usable = ctypes.c_size_t()
                result = self.admit(buffer, len(data), 0, ctypes.byref(kind), ctypes.byref(usable))
                self.assertEqual(result, 0)
                self.assertEqual(kind.value, expected)
                self.assertEqual(usable.value, len(data))


if __name__ == '__main__':
    unittest.main()
