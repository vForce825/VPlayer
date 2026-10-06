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
import errno
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AdmissionView(ctypes.Structure):
    _fields_ = [('start_offset', ctypes.c_size_t), ('packet_offset', ctypes.c_size_t),
                ('reason', ctypes.c_int), ('pid', ctypes.c_int)]


def crc_section(data):
    crc = 0xffffffff
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04c11db7 if crc & 0x80000000 else 0)) & 0xffffffff
    return data + crc.to_bytes(4, 'big')


def psi_packet(pid, section):
    payload = bytes([0]) + section
    return bytes([0x47, 0x40 | (pid >> 8), pid & 255, 0x10]) + payload + bytes([255]) * (184 - len(payload))


def ordinary_si_packets():
    # Empty current NIT/EIT and a TDT, all authored per ETSI EN 300 468.
    nit = crc_section(bytes.fromhex('40 B0 0D 00 01 C1 00 00 F0 00 F0 00'))
    eit = crc_section(bytes.fromhex('4E B0 0F 00 01 C1 00 00 00 01 00 01 00 4E'))
    tdt = bytes.fromhex('70 70 05 EA 60 12 34 56')
    return [psi_packet(0x10, nit), psi_packet(0x12, eit), psi_packet(0x14, tdt)]
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
        cls.view = cls.library.vp_source_admit_container_with_view
        cls.view.argtypes = cls.admit.argtypes + [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(AdmissionView)]
        cls.view.restype = ctypes.c_int

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

    @staticmethod
    def ordinary_ts():
        return (ROOT / 'Tests/VPlayerTests/Fixtures/Media/progressive-h264-aac.ts').read_bytes()

    def admission(self, data, prefix=0):
        buffer = ctypes.create_string_buffer(data)
        kind, usable = ctypes.c_int32(), ctypes.c_size_t()
        result = self.admit(buffer, len(data), prefix, ctypes.byref(kind), ctypes.byref(usable))
        return result, kind.value, usable.value

    @staticmethod
    def pid(packet):
        return ((packet[1] & 31) << 8) | packet[2]

    @staticmethod
    def tdt_packet():
        # ETSI EN 300 468 section 5.2.5: one ordinary TDT, no CRC.
        return bytes.fromhex('47 40 14 10 00 70 70 05 EA 60 12 34 56') + bytes([255]) * 175

    def test_raw_live_prefix_acquires_tables_after_initial_media(self):
        data = self.ordinary_ts()[3 * 188:3 * 188 + 262144]
        self.assertEqual(self.pid(data[:188]), 256)
        self.assertEqual(self.admission(data, prefix=1), (0, 1, len(data) // 188 * 188))

    def test_normal_time_date_information_does_not_reject_media(self):
        data = self.ordinary_ts()
        for source in [self.tdt_packet() + data, data + self.tdt_packet()]:
            self.assertEqual(self.admission(source), (0, 1, len(source)))

    def test_table_discovery_does_not_depend_on_packet_order(self):
        data = self.ordinary_ts()
        packets = [data[i:i + 188] for i in range(0, len(data), 188)]
        pat = next(p for p in packets if self.pid(p) == 0)
        pmt = next(p for p in packets if self.pid(p) == 4096)
        media = next(p for p in packets if self.pid(p) == 256)
        for first in [[media, pat, pmt], [pmt, media, pat]]:
            source = b''.join(first)
            self.assertEqual(self.admission(source), (0, 1, len(source)))

    def test_missing_tables_and_undeclared_payload_remain_rejected(self):
        data = self.ordinary_ts()
        packets = [data[i:i + 188] for i in range(0, len(data), 188)]
        for excluded in [0, 4096]:
            source = b''.join(p for p in packets if self.pid(p) != excluded)
            self.assertEqual(self.admission(source)[0], -errno.EINVAL)
        # A normal-sized transport packet on an undeclared media PID.
        unknown = bytearray(next(p for p in packets if self.pid(p) == 256))
        unknown[1] = (unknown[1] & 0xe0) | 2
        unknown[2] = 0
        self.assertEqual(self.admission(data + unknown)[0], -errno.EINVAL)

    def test_all_ordinary_si_kinds_preserve_complete_container(self):
        data = self.ordinary_ts()
        for packet in ordinary_si_packets():
            for offset in [0, 188 * 30, len(data)]:
                source = data[:offset] + packet + data[offset:]
                self.assertEqual(self.admission(source), (0, 1, len(source)))

    def admitted_view(self, data, prefix):
        buffer = ctypes.create_string_buffer(data)
        kind, usable, view = ctypes.c_int32(), ctypes.c_size_t(), AdmissionView()
        result = self.view(buffer, len(data), prefix, ctypes.byref(kind), ctypes.byref(usable), None, None, ctypes.byref(view))
        self.assertEqual((result, kind.value, usable.value), self.admission(data, prefix))
        return result, view

    def test_prefix_view_shrinks_without_changing_original_usable_size(self):
        data = self.ordinary_ts()[3 * 188:3 * 188 + 262144]
        result, view = self.admitted_view(data, 1)
        self.assertEqual(result, 0)
        self.assertEqual(view.start_offset, 53204)
        self.assertEqual(data[view.start_offset + 1] & 31, 0)
        self.assertEqual(self.admitted_view(self.ordinary_ts(), 0)[1].start_offset, 0)

    def test_prefix_native_header_window_ends_before_packet_173(self):
        data = self.ordinary_ts()
        pat, pmt = data[188:376], data[376:564]
        null = bytes.fromhex('47 1F FF 10') + bytes([255]) * 184
        for index in [172, 173]:
            source = pat + null * (index - 1) + pmt
            result, view = self.admitted_view(source, 1)
            self.assertEqual(result, 0 if index == 172 else -errno.EINVAL)
            self.assertEqual(view.reason, 0 if index == 172 else 8)
            self.assertEqual(self.admitted_view(source, 0)[0], 0)

    def test_stable_tables_reject_changed_identity_and_si_collisions(self):
        data = self.ordinary_ts()
        pat, pmt = data[188:376], data[376:564]
        def replace_section(packet, change):
            start = 5
            size = 3 + ((packet[start + 1] & 15) << 8) + packet[start + 2]
            section = bytearray(packet[start:start + size - 4])
            change(section)
            return psi_packet(self.pid(packet), crc_section(section))
        changed_pat = replace_section(pat, lambda s: s.__setitem__(5, s[5] + 2))
        changed_pmt = replace_section(pmt, lambda s: s.__setitem__(5, s[5] + 2))
        wrong_program = replace_section(pmt, lambda s: s.__setitem__(4, 2))
        media_si = replace_section(pmt, lambda s: s.__setitem__(slice(13, 15), bytes.fromhex('E0 14')))
        pmt_si = replace_section(pat, lambda s: s.__setitem__(slice(10, 12), bytes.fromhex('E0 12')))
        for source in [data + changed_pat, data + changed_pmt, pat + wrong_program,
                       pat + media_si, pmt_si + pmt]:
            self.assertEqual(self.admission(source)[0], -errno.EINVAL)

    def test_packet_passes_remain_cancellable(self):
        data = self.ordinary_ts()
        callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
        for stop_at in [1, len(data) // 188 + 1]:
            calls = 0
            @callback_type
            def interrupt(_):
                nonlocal calls
                calls += 1
                return calls >= stop_at
            buffer = ctypes.create_string_buffer(data)
            kind, usable, view = ctypes.c_int32(), ctypes.c_size_t(), AdmissionView()
            result = self.view(buffer, len(data), 0, ctypes.byref(kind), ctypes.byref(usable),
                               ctypes.cast(interrupt, ctypes.c_void_p), None, ctypes.byref(view))
            self.assertEqual(result, -errno.ECANCELED)
            self.assertEqual(calls, stop_at)

    def test_psi_pointer_can_skip_only_stuffing(self):
        data = self.ordinary_ts()
        pat = data[188:376]
        stuffed = pat[:4] + bytes([2, 255, 255]) + pat[5:-2]
        self.assertEqual(self.admission(stuffed + data[376:])[0], 0)

    def test_single_program_and_eight_declared_tracks_remain_the_bounds(self):
        data = self.ordinary_ts()
        pat = data[188:376]
        def table(table_id, extension, body):
            header = extension.to_bytes(2, 'big') + bytes.fromhex('C1 00 00')
            length = len(header) + len(body) + 4
            return crc_section(bytes([table_id, 0xB0 | (length >> 8), length & 255]) + header + body)
        for count in [8, 9]:
            body = bytes.fromhex('E1 00 F0 00')
            for index in range(count):
                body += bytes([0x1B if index == 0 else 0x0F, 0xE1, index, 0xF0, 0])
            source = pat + psi_packet(4096, table(2, 1, body))
            self.assertEqual(self.admission(source)[0], 0 if count == 8 else -errno.EINVAL)
        two_programs = psi_packet(0, table(0, 1, bytes.fromhex('00 01 F0 00 00 02 F0 01')))
        self.assertEqual(self.admission(two_programs + data[376:])[0], -errno.EINVAL)

    def test_additional_psi_sections_are_outside_the_single_table_subset(self):
        data = self.ordinary_ts()
        pat, pmt = data[188:376], data[376:564]
        length = 3 + ((pat[6] & 15) << 8) + pat[7]
        section = pat[5:5 + length]
        self.assertEqual(self.admission(psi_packet(0, section + section) + pmt)[0], -errno.EINVAL)


if __name__ == '__main__':
    unittest.main()
