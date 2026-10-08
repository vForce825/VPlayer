#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Structural guardrails; native pipeline tests prove event ordering/ownership."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class SampleBufferSourceMetadataTests(unittest.TestCase):
    def test_tracks_publish_source_only_after_selected_assembly_installation(self):
        text=(ROOT/'Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift').read_text()
        self.assertIn('assembly = candidate\n            publishSourceMediaInformationIsolated()',text)
        helper=text.split('private func publishSourceMediaInformationIsolated()',1)[1].split('private func publishMediaInformationIfReadyIsolated()',1)[0]
        for contract in ['guard !terminal', 'scanMode: nil', 'validatedFrameRate(video.frameRate)',
                         'mediaInformation?.isSourceProbe == false', 'eventSink(.mediaInformation(information, generation: generation))']:
            self.assertIn(contract,helper)
        self.assertNotIn('isClassificationResolved',helper)
        self.assertNotIn('updateReadiness',helper)
    def test_source_metadata_is_never_readiness_authority(self):
        text=(ROOT/'Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift').read_text()
        for start,end in [('private func updateReadinessIsolated()', 'private func displayModeSwitchStartedIsolated()'),
                          ('private func displayModeSwitchEndedIsolated()', 'private func resumeDisplayForOpenReadinessGateIsolated()'),
                          ('private func resumeDisplayForOpenReadinessGateIsolated()', 'private func')]:
            section=text.split(start,1)[1].split(end,1)[0]
            self.assertIn('mediaInformation?.isSourceProbe == false',section)
    def test_epoch_resets_republish_only_with_current_format_evidence(self):
        text=(ROOT/'Sources/VPlayerPlayback/Pipeline/PlaybackPipeline.swift').read_text()
        self.assertEqual(text.count('if videoFormat != nil { publishSourceMediaInformationIsolated() }'),2)
        begin=text.split('private func beginTrackEpochIsolated()',1)[1].split('private func configureCurrentGenerationIsolated',1)[0]
        self.assertIn('videoFormat = nil',begin)
        self.assertNotIn('publishSourceMediaInformation',begin)
if __name__=='__main__': unittest.main()
