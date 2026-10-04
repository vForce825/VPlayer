#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Linux source guard for native hash allocations; Apple tests verify semantics.

This is deliberately not a substitute for the CoreMedia runtime tests.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Sources/VPlayerPlayback/HLS/SegmentedFMP4Writer.swift").read_text()


class NativeSamplePayloadContractTests(unittest.TestCase):
    def test_native_freeze_has_no_payload_sized_temporary_copy(self):
        freeze = SOURCE.split("private struct NativeSampleFacts:", 1)[1].split(
            "private final class AVAssetSegmentedFMP4SystemWriter:", 1)[0]
        self.assertNotIn("CMBlockBufferCopyDataBytes", freeze,
                         "native evidence hashing must borrow each backing, not copy its payload")
        self.assertNotIn("Data(count:", freeze)
        self.assertIn("nativeSamplePayloadDigest(block)", freeze)
        helper = SOURCE.split("func nativeSamplePayloadDigest(", 1)[1].split(
            "private final class AVAssetSegmentedFMP4SystemWriter:", 1)[0]
        self.assertIn("CMBlockBufferGetDataPointer", helper)
        self.assertIn("hasher.update(bufferPointer:", helper)
        self.assertIn("withExtendedLifetime(block)", helper)
        self.assertNotIn("CMBlockBufferCopyDataBytes", helper)
        self.assertNotIn("Data(count:", helper)

    def test_validation_checkpoints_are_preserved(self):
        self.assertEqual(SOURCE.count("NativeSampleFacts.freeze("), 5)
        self.assertIn("try validatesSource(facts)", SOURCE)
        self.assertIn("try operation.validatesSource(operation.facts)", SOURCE)
        self.assertIn("try Task.checkCancellation()", SOURCE)
        self.assertIn("awaitingAppend?.identity == operation.identity", SOURCE)


if __name__ == "__main__":
    unittest.main()
