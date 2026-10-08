#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Portable production-wiring checks; actual output/lifecycle tests run on Apple CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


class AirPlayOutputModeContract(unittest.TestCase):
    def require(self, fragment, text):
        self.assertTrue(fragment in text, f'Missing production contract: {fragment}')

    def exclude(self, fragment, text):
        self.assertFalse(fragment in text, f'Unexpected production contract: {fragment}')

    def test_ui_exposes_only_confirmed_friendly_output_and_preserves_local_mode(self):
        text = source('Sources/VPlayerApp/Player/PlaybackMediaInformationPresentation.swift')
        self.require('var airPlayOutputText: String?', text)
        for label in ['直通', '重封装', '音频转码', '视频转码', '混合转码', '准备中']:
            self.require(label, text)
        self.exclude('var sourceRoutingText', text)
        self.exclude('来源：', text)
        self.exclude('规划路径', text)
        self.require('information.sourceCategory != nil || information.airPlayOutputMode != nil', text)
        self.require('guard !information.isAudioOnly else { return "" }', text)
        overlay = source('Sources/VPlayerApp/Player/PlayerChannelInfoOverlay.swift')
        self.require('mediaInformation?.isAudioOnly != true', overlay)
        self.require('player-channel-airplay-output', overlay)

    def test_generated_receipt_reads_real_branches_after_all_track_publication(self):
        text = source('Sources/VPlayerPlayback/HLS/SystemHLSMediaGraphAuthority.swift')
        self.require('private func confirmedAirPlayOutputModeLocked()', text)
        mapping = text.split('private func confirmedAirPlayOutputModeLocked()', 1)[1].split('func awaitAllTrackPlayablePrefix', 1)[0]
        for branch in ['interlacedVideoOutput != nil', 'videoWriter != nil', 'audioBranch != nil',
                       'sourceAACBranch != nil || dolbyBranch != nil']:
            self.require(branch, mapping)
        self.exclude('plan.audio', mapping)
        self.exclude('selectedCompressedAudio', mapping)
        prefix = text.split('private func prepareAllTrackPlayablePrefix()', 1)[1].split('func finishAllTracksAtNaturalEOF', 1)[0]
        self.assertLess(prefix.index('publication.waitForVisible'), prefix.index('confirmedAirPlayOutputModeLocked()'))
        self.require('generatedSource?.isCurrent != false', prefix)
        self.require('withAirPlayOutputMode(mode)', prefix)

    def test_native_confirms_only_successful_selection_and_keeps_nil_invalidations(self):
        text = source('Sources/VPlayerPlayback/HLS/Native/NativeHLSItemCoordinator.swift')
        self.assertEqual(text.count('publishSelectedMediaInformation(snapshot)'), 3)
        self.assertEqual(text.count('publishSelectedMediaInformation(afterPreroll)'), 1)
        self.require('snapshot.information?.withAirPlayOutputMode(.passthrough)', text)
        self.require('.init(audioOnlyAirPlayOutputMode: .passthrough)', text)
        self.assertEqual(text.count('metadata.publish(.init(lifecycle: item.outputLifecycleEpoch, information: nil))'), 2)
        self.require('metadata.publish(nil)', text)

    def test_stale_routed_source_cannot_fall_back_to_an_unvalidated_snapshot(self):
        text = source('Sources/VPlayerPlayback/Pipeline/HLSAVPlayerPlaybackBackend.swift')
        projection = text.split('func preparedMediaInformation(for lifecycle:', 1)[1].split('private func currentSourceRouting', 1)[0]
        self.require('guard let routing = currentSourceRouting(for: lifecycle) else { return nil }', projection)
        self.require('sourceDependencies != nil', projection)
        self.exclude('airPlayOutputMode: .passthrough', projection)

    def test_fixed_slot_budget_is_not_expanded(self):
        text = source('Sources/VPlayerPlayback/Pipeline/PlaybackSessionEventRelay.swift')
        self.require('static let payloadStride = 48', text)
        self.require('validate(MediaPayload.self)', text)
        tests = source('Tests/VPlayerTests/Playback/Control/Task9ReconstructedRegressionTests.swift')
        self.require('testPipelineAirPlayOutputMetadataFitsAndRoundTripsInExistingFixedSlot', tests)


if __name__ == '__main__':
    unittest.main()
