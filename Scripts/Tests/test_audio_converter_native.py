#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Run against a shared library compiled from production VPFFmpegAudioConverter.c.
Set VPLAYER_AUDIO_CONVERTER_LIBRARY; ffmpeg is used for the real AAC decode case.
"""
import ctypes as C
import errno
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

LIBRARY = os.environ.get("VPLAYER_AUDIO_CONVERTER_LIBRARY")


@unittest.skipUnless(LIBRARY, "Set VPLAYER_AUDIO_CONVERTER_LIBRARY to production C build")
class AudioConverterNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = C.CDLL(LIBRARY)
        cls.lib.vp_ffmpeg_audio_converter_create.argtypes = [C.POINTER(C.c_uint8), C.c_int,
            C.POINTER(C.c_uint8), C.c_int, C.c_int, C.POINTER(C.c_double), C.POINTER(C.c_void_p)]
        cls.lib.vp_ffmpeg_audio_converter_capacity.argtypes = [C.c_void_p, C.c_int]
        cls.lib.vp_ffmpeg_audio_converter_convert.argtypes = [C.c_void_p, C.POINTER(C.c_float),
            C.c_int, C.POINTER(C.c_float), C.c_int]
        cls.lib.vp_ffmpeg_audio_converter_destroy.argtypes = [C.c_void_p]

    def create(self, channels, rate):
        labels = (C.c_uint8 * channels)(*([2] if channels == 1 else [0, 1]))
        matrix = (C.c_double * (channels * channels))(
            *[float(i == j) for i in range(channels) for j in range(channels)])
        handle = C.c_void_p()
        self.assertEqual(self.lib.vp_ffmpeg_audio_converter_create(labels, channels,
            labels, channels, rate, matrix, C.byref(handle)), 0)
        self.addCleanup(self.lib.vp_ffmpeg_audio_converter_destroy, handle)
        return handle

    def convert(self, handle, samples, channels):
        frames = len(samples) // channels
        capacity = self.lib.vp_ffmpeg_audio_converter_capacity(handle, frames)
        self.assertGreater(capacity, 0)
        output = (C.c_float * (capacity * channels))()
        result = self.lib.vp_ffmpeg_audio_converter_convert(handle,
            (C.c_float * len(samples))(*samples), frames, output, capacity)
        self.assertGreaterEqual(result, 0, f"production converter rejected finite PCM: {result}")
        values = list(output[:result * channels])
        self.assertTrue(all(math.isfinite(x) and abs(x) <= 1 for x in values))
        return values

    def test_finite_codec_headroom_is_saturated_at_output(self):
        self.assertEqual(self.convert(self.create(2, 48000), [1.0002205, -1.01, .5, -.5], 2),
                         [1, -1, .5, -.5])

    def test_high_amplitude_src_and_drain_preserve_frame_count(self):
        for rate in (24000, 32000, 44100):
            with self.subTest(rate=rate):
                handle = self.create(1, rate)
                values = [.99 if (i // 20) % 2 else -.99 for i in range(rate)]
                output = []
                for start in range(0, rate, 1024):
                    output += self.convert(handle, values[start:start + 1024], 1)
                while True:
                    tail = self.convert(handle, [], 1)
                    output += tail
                    if not tail:
                        break
                self.assertEqual(len(output), 48000)
                self.assertTrue(any(abs(x) == 1 for x in output))

    def test_real_aac_decoded_peak_does_not_end_playback(self):
        with tempfile.TemporaryDirectory() as directory:
            encoded = Path(directory) / "loud.aac"
            pcm = Path(directory) / "loud.f32"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                "aevalsrc=0.99*sin(2*PI*997*t)|0.99*sin(2*PI*997*t):s=48000:d=0.5",
                "-c:a", "aac", "-b:a", "128k", "-f", "adts", str(encoded)], check=True)
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(encoded), "-c:a", "pcm_f32le",
                "-f", "f32le", str(pcm)], check=True)
            data = pcm.read_bytes()
            samples = struct.unpack("<" + "f" * (len(data) // 4), data)
            self.assertGreater(max(map(abs, samples)), 1, "fixture must exercise actual decoder overshoot")
            handle = self.create(2, 48000)
            output = []
            for start in range(0, len(samples), 2048):
                output += self.convert(handle, samples[start:start + 2048], 2)
            output += self.convert(handle, [], 2)
            self.assertEqual(len(output), len(samples))

    def test_low_rate_capacity_queries_leave_src_state_unchanged(self):
        queried = self.create(1, 4000)
        control = self.create(1, 4000)
        capacity = self.lib.vp_ffmpeg_audio_converter_capacity
        self.assertEqual(capacity(queried, 16384), -errno.EOVERFLOW)
        self.assertEqual(capacity(queried, 8192), 98304)
        self.assertEqual(capacity(queried, 16384), -errno.EOVERFLOW)
        self.assertEqual(capacity(queried, 8192), 98304)
        for index, source in enumerate(([0] * 8192, [.1] * 1024, [])):
            self.assertEqual(self.convert(queried, source, 1), self.convert(control, source, 1))
            if index == 0:
                # SRC now has a real nonzero delay; probing must account for it
                # without consuming it, even after another overflow rejection.
                self.assertEqual(capacity(queried, 16384), -errno.EOVERFLOW)
                self.assertGreater(capacity(queried, 8192), 98304)
            self.assertEqual(capacity(queried, 8192), capacity(control, 8192))

    def test_nonfinite_input_still_fails_without_poisoning_resampler(self):
        for value in (math.nan, math.inf, -math.inf):
            handle = self.create(1, 48000)
            output = (C.c_float * 32)()
            result = self.lib.vp_ffmpeg_audio_converter_convert(handle,
                (C.c_float * 1)(value), 1, output, 32)
            self.assertEqual(result, -22)
            self.assertEqual(self.convert(handle, [.25], 1), [.25])


if __name__ == "__main__":
    unittest.main()
