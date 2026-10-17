#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""隔行 writer 的精确算术与接线检查；不能替代 Apple 平台 Swift 回归。"""
from fractions import Fraction
from math import ceil
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(name):
    return (ROOT / 'Sources/VPlayerPlayback/HLS' / name).read_text()


class InterlacedWriterRegressionContractTests(unittest.TestCase):
    def test_logged_duration_changes_while_pts_remains_continuous(self):
        self.assertEqual(11818800 + 3600, 11822400)
        canonical, logged = Fraction(3600, 180000), Fraction(3510, 180000)
        self.assertEqual(canonical - logged, Fraction(1, 2000))
        self.assertLess(abs(logged - canonical), canonical / 20)
        self.assertEqual(20 * abs(logged - canonical), canonical / 2)
        self.assertGreater(22 * abs(logged - canonical), canonical / 2)
        # 平衡抖动可抵消；单向漂移不能不断重新锚定而绕过半场预算。
        self.assertEqual((Fraction(3510, 180000) - canonical)
                         + (Fraction(3690, 180000) - canonical), 0)

    def test_encoded_segment_budget_avoids_large_i_frame_multiplication(self):
        hard_bytes, payload = 64 * 1024 * 1024, 400000
        self.assertGreater((payload + 64) * 202, hard_bytes)
        declared, count = 18360000, 100
        budget = (ceil(Fraction((count + 2) * declared, 50 * 8))
                  + (count + 2) * 64)
        self.assertEqual(budget, 4688328)
        actual = payload + 99 * 1000 + 100 * 64
        self.assertLess(actual, budget)
        self.assertLess(budget * 2, hard_bytes)

    def test_production_uses_one_frozen_output_frame_rate(self):
        graph = source('SystemHLSMediaGraphAuthority.swift')
        self.assertIn('outputFrameRate: outputFrameRate', graph)
        self.assertIn('encodedVideoEnvelope: encoder.writerEnvelope', graph)
        self.assertIn('encodedVideoEnvelope: encodedVideoEnvelope', graph)
        branch = source('HLSVideoTranscodeBranch.swift')
        self.assertIn('cumulativeDurationCorrection', branch)
        self.assertIn('previousBatchEnd', branch)
        self.assertIn('canonicalDuration ?? frame.duration', branch)
        writer = source('SegmentedFMP4Writer.swift')
        self.assertIn('guard previousDuration == duration else { return false }', writer)
        self.assertIn('self.encodedVideoEnvelope = resolvedEnvelope', writer)
        self.assertIn('encodedVideoEnvelope.accepts(output)', writer)

    def test_diagnostic_precedes_optional_context_without_private_inputs(self):
        graph = source('SystemHLSMediaGraphAuthority.swift')
        context = graph.split('private func failureContext(', 1)[1].split('\n        private func makeWriter(', 1)[0]
        self.assertIn('return admission + "duration=', context)
        self.assertIn('writer?.admissionFailureDiagnostic', context)
        for forbidden in ['sourceURL', 'absoluteString', 'payload.description']:
            self.assertNotIn(forbidden, context)


if __name__ == '__main__':
    unittest.main()
