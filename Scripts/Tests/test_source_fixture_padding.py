#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Container arithmetic controls only; these are not encoded-media decode evidence."""
import importlib.util
from pathlib import Path
import struct
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'Scripts/Support/pad_source_fixture_au.py'

def word(value):return struct.pack('>I',value)
def box(kind,payload):return word(len(payload)+8)+kind.encode()+payload

def fixture():
    avcc=box('avcC',bytes([1,66,0,30,255]))
    sample_entry=box('avc1',bytes(78)+avcc)
    stsd=box('stsd',word(0)+word(1)+sample_entry)
    moov=box('moov',box('trak',box('mdia',box('minf',box('stbl',stsd)))))
    samples=[bytes([0,0,0,2,0x65,0x80]),bytes([0,0,0,2,0x41,0x80])]
    tfhd=box('tfhd',word(0x020000)+word(1))
    def moof(offset):return box('moof',box('mfhd',word(0)+word(1))+box('traf',tfhd+
        box('trun',word(0x201)+word(2)+struct.pack('>i',offset)+word(6)+word(6))))
    fragment=moof(0);fragment=moof(len(fragment)+8)
    return box('ftyp',b'isom0000')+moov+fragment+box('mdat',b''.join(samples))

class PaddingContracts(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(),'public fixture padding helper must exist')
        spec=importlib.util.spec_from_file_location('padding',SOURCE)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)

    def test_exact_limit_and_plus_one_preserve_other_sample_bytes(self):
        original=fixture()
        for target in (1_048_576,1_048_577):
            padded=self.module.pad(original,target)
            self.assertEqual(self.module.first_sample(padded)['size'],target)
            self.assertEqual(len(padded)-len(original),target-6)
            info=self.module.first_sample(padded)
            payload=padded[info['offset']:info['offset']+target]
            self.assertEqual(payload[:6],bytes([0,0,0,2,0x65,0x80]))
            filler_length=struct.unpack('>I',payload[6:10])[0]
            self.assertEqual(filler_length,target-10)
            self.assertEqual(payload[10],12);self.assertEqual(payload[-1],128)
            self.assertEqual(padded[info['offset']+target:],bytes([0,0,0,2,0x41,0x80]))

    def test_refuses_unreviewed_target_and_truncated_container(self):
        for target in (0,6,1_048_575,1_048_578,1<<32):
            with self.assertRaises(ValueError):self.module.pad(fixture(),target)
        with self.assertRaises(ValueError):self.module.pad(fixture()[:-1],1_048_576)

if __name__=='__main__':unittest.main()
