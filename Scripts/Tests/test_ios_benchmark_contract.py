#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source/fixture arithmetic contracts; native XCTest is still required."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Tests/VPlayerTests/Deinterlace/YADIFGoldenPixelTests.swift'


class IOSBenchmarkContracts(unittest.TestCase):
    def setUp(self):
        self.source = SOURCE.read_text()

    def test_full_size_benchmark_is_release_only_and_keeps_every_case_and_sample(self):
        self.assertRegex(self.source, r'#if !DEBUG\s+func testCPUYADIFBenchmark')
        body = self.source.split('func testCPUYADIFBenchmark', 1)[1].split('\n    #endif', 1)[0]
        self.assertIn('[(1_920, 1_080), (3_840, 2_160)]', body)
        self.assertIn('for depth in [8, 10]', body)
        self.assertIn('for sample in 0..<5', body)
        self.assertEqual(body.count('try CPUVideoProcessing.yadif(job: job, outputs: outputs)'), 2)
        self.assertIn('spatialOnly: false', body)
        self.assertNotIn('executionTimeAllowance', body)
        self.assertNotIn('XCTSkip', body)

    def test_benchmark_uses_bulk_fixture_and_unbuffered_phase_diagnostics(self):
        body = self.source.split('func testCPUYADIFBenchmark', 1)[1].split('\n    #endif', 1)[0]
        self.assertIn('fillCPUBenchmarkPlane(', body)
        self.assertNotIn('for x in 0..<width', body)
        for phase in ['setup_begin', 'setup_end', 'output_begin', 'output_end',
                      'warmup_begin', 'warmup_end', 'sample_begin', 'sample_end']:
            self.assertIn(phase, body)
        self.assertIn('setup_ms=', body)
        self.assertIn('FileHandle.standardError.write', self.source)
        self.assertIn('simulator-not-iphone-hardware', body)
        self.assertIn('device-short-run-not-thermal-qualification', body)

    def test_debug_keeps_exact_goldens_and_native_bulk_fill_equivalence(self):
        after_benchmark = self.source.split('func testCPUYADIFBenchmark', 1)[1].split('\n    #endif', 1)[1]
        self.assertIn('func testCPUBenchmarkPeriodicFillMatchesOriginalFormulaAndPreservesPadding', after_benchmark)
        self.assertIn('func testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly', after_benchmark)
        self.assertIn('XCTAssertEqual(actual, expected, "\\(name) \\(stem) CPU adapter")', after_benchmark)

    def test_periodic_rotation_matches_original_values_across_wraps(self):
        # Independent arithmetic proof, not execution of the native helper.
        for depth, period, inverse in [(8, 256, 197), (10, 1024, 709)]:
            self.assertEqual((13 * inverse) % period, 1)
            template = [(13 * x) % period for x in range(2 * period)]
            for width in [1, 7, 257, 1025, 3840]:
                for y in [0, 1, 255, 256, 1023, 1024, 2159]:
                    for seed in range(3):
                        offset = ((17 * y + 31 * seed) * inverse) % period
                        actual = []
                        while len(actual) < width:
                            actual += template[offset:offset + min(period, width - len(actual))]
                        shift = 6 if depth == 10 else 0
                        self.assertEqual([code << shift for code in actual],
                            [((13 * x + 17 * y + 31 * seed) % period) << shift for x in range(width)])


if __name__ == '__main__':
    unittest.main()
