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
        # Five original validation sites plus the two-sided zero-copy wrapper check.
        self.assertEqual(SOURCE.count("NativeSampleFacts.freeze("), 7)
        self.assertIn('stage: "input-wrapper"', SOURCE)
        self.assertIn("try validatesSource(facts)", SOURCE)
        self.assertIn("try operation.validatesSource(operation.facts)", SOURCE)
        self.assertIn("try Task.checkCancellation()", SOURCE)
        self.assertIn("awaitingAppend?.identity == operation.identity", SOURCE)

    def test_exact_metadata_failures_identify_the_copy_boundary(self):
        facts = SOURCE.split("private struct NativeSampleFacts:", 1)[1].split(
            "func nativeSamplePayloadDigest(", 1)[0]
        self.assertIn("guard self == other else", facts,
                      "diagnostics must retain full exact facts equality")
        self.assertIn("HLS_NATIVE_SAMPLE_MISMATCH", facts)
        self.assertIn("#if DEBUG", facts)
        self.assertIn("timing.indices.first", facts,
                      "print only the first timing difference, not a whole sample history")
        for stage in ["input-wrapper", "ready-header", "native-return"]:
            self.assertIn(f'stage: "{stage}"', SOURCE)


if __name__ == "__main__":
    unittest.main()
