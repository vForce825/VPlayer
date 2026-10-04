#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable source-level performance guard; runtime equivalence is covered by XCTest.

This does not execute Accelerate or claim a device speedup. It keeps the bounded
quantized dot product out of Swift's checked scalar inner loop and retains the
per-encoder, two-pass calibration contract.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/VPlayerPlayback/HLS/AACPrimingCalibrator.swift"


class AACPrimingCorrelationSourceTests(unittest.TestCase):
    def test_quantized_correlation_uses_double_precision_vector_dot_product(self):
        source = SOURCE.read_text()
        body = source.split("static func leadingOffset(", 1)[1].split(
            "// 容器 reader", 1)[0]
        self.assertTrue("import Accelerate" in source, "Accelerate must be imported")
        self.assertIn("vDSP_dotprD(", body,
                      "The 8193 x 2048 checked scalar search must use the exact Double vector kernel")
        self.assertNotRegex(body, r"for\s+index\s+in\s+0\.\.<width")
        self.assertNotRegex(body, r"vDSP_dotpr\(",
                            "Float cannot preserve a one-unit score difference near 2^41")
        self.assertEqual(body.count("* 32_767).rounded()"), 2)
        self.assertIn("best > 0, best > second", body)

    def test_every_encoder_keeps_both_owned_calibration_passes(self):
        body = SOURCE.read_text().split("func calibrate(plan:", 1)[1].split(
            "func cancel()", 1)[0]
        self.assertRegex(body, r"let first = try await calibratePass\(encoder, index: 1\)")
        self.assertRegex(body, r"let second = try await calibratePass\(encoder, index: 2,")
        self.assertLess(body.index("try encoder.reset()"), body.index("let second ="))
        self.assertIn("try encoder.finalize(first: first, second: second, firstReset: firstReset)", body)


if __name__ == "__main__":
    unittest.main()
