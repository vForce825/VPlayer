#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Harness wiring guards only; actual Dolby callback behavior requires Apple tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Tests/VPlayerTests/Playback/HLS/DolbyBranchIntegrationTests.swift").read_text()


class DolbyBranchNativeContractTests(unittest.TestCase):
    def test_factory_preserves_source_layout_at_native_validation_boundary(self):
        graph = SOURCE.split("private final class DolbyBranchTestGraph ", 1)[1].split(
            "private struct DolbyObservedSample:", 1)[0]
        factory = SOURCE.split("private final class DolbyBranchWriterFactory:", 1)[1].split(
            "private final class DolbyWeakRelay:", 1)[0]
        self.assertIn("sourceLayout: fixture.source.channelLayout", graph)
        self.assertIn("compressedSourceLayout: sourceLayout", factory,
                      "omitting the layout silently disables production callback validation")

    def test_native_rejection_cannot_be_minted_by_posthoc_test_validation(self):
        for name, next_name in [
            ("testNativeEAC3BranchPublishesValidatedSideLayoutOrRejectsMissingLayout",
             "testRealNativePredecessorRolloverPreservesAliasesOrRejectsMissingLayout"),
            ("testRealNativePredecessorRolloverPreservesAliasesOrRejectsMissingLayout",
             "assertMissingNativeLayoutWasRejected"),
        ]:
            body = SOURCE.split(f"func {name}(", 1)[1].split(f"func {next_name}(", 1)[0]
            self.assertIn("catch SegmentedFMP4WriterFailure.compressedAudioCompatibilityRequired", body)
            self.assertNotIn("catch CompressedAudioInitializationRejection", body)
            self.assertGreater(body.index("DolbyWriterInitializationEvidence.validate("),
                               body.rindex("catch"),
                               "post-hoc assertions must not be accepted as native rejection")

    def test_native_publication_requires_writer_issued_layout_evidence(self):
        factory = SOURCE.split("private final class DolbyBranchWriterFactory:", 1)[1].split(
            "private final class DolbyWeakRelay:", 1)[0]
        self.assertIn("object.publicationEvidence?.dolbyInitialization", factory)
        self.assertIn("Unexpected native initialization without validated layout evidence", factory)


if __name__ == "__main__":
    unittest.main()
