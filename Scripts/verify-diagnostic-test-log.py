#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Require explicit XCTest passed outcomes; absent/skipped cases are not evidence."""
import argparse
from pathlib import Path
import re

CASES = {
    "audio": {
        "HLSAVPlayerBackendTests": [
            "testSyntheticHLG50AC3OriginalAACFragmentsDecodeContinuously",
            "testSyntheticAACSilenceMeterDetectsOffsetTwentyOneMillisecondMute",
        ],
        "SegmentedFMP4WriterTests": [
            "testTrackBundlesUseIndependentOneInputHLSWritersAndRetainDelegate",
            "testAACNativeMovieFragmentSequenceContinuesAcrossWriterWindows",
            "testWriterWindowFragmentSequenceAdvancesByMediaCountNotWriterIdentity",
            "testNativeMovieFragmentSequenceUInt32BoundaryAndInvalidConfigurations",
        ],
    },
    "focus": {
        "ChannelCardFocusDiagnosticTests": [
            "testFlatPlaylistCardsLoseVisualFocusAfterScrolling",
            "testGroupedPlaylistCardsLoseVisualFocusAfterScrolling",
        ],
        "ChannelCardFocusRasterTests": [
            "testPixelMeasurementDetectsScaleEvenWhenAccessibilityFrameDoesNotChange",
            "testCGImageDecodingPreservesScreenPixelCoordinates",
            "testClippedMarkerIsUnavailableRatherThanAnUnderestimatedWidth",
            "testMissingMarkerIsUnavailableRatherThanZeroWidth",
            "testAnotherCardsMarkerCannotStandInForTheRequestedCard",
        ],
    },
}


def verify(text, group):
    passed = 0
    for cls, cases in CASES[group].items():
        for case in cases:
            pattern = rf"Test Case '-\[(?:\w+\.)?{re.escape(cls)} {re.escape(case)}\]' (passed|failed|skipped) \("
            outcomes = re.findall(pattern, text)
            if outcomes != ["passed"]:
                raise ValueError(f"{cls}/{case}: expected exactly one passed outcome, got {outcomes}")
            passed += 1
    return passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=CASES)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    passed = verify(args.log.read_text(), args.group)
    print(f"{args.group.upper()}_DIAGNOSTIC_REQUIRED_TESTS_PASSED={passed}; skipped=0")
