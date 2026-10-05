#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Bounded diagnosis wiring only; native source proof semantics require Apple CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRODUCER = ROOT / 'Sources/VPlayerPlayback/HLS/DolbyAudioSourceProducer.swift'
ASSEMBLER = ROOT / 'Sources/VPlayerPlayback/Audio/CompressedAudioAssembler.swift'
TIMELINE = ROOT / 'Sources/VPlayerPlayback/HLS/HLSTimelineCoordinator.swift'


class DolbyProofDiagnosticTests(unittest.TestCase):
    def test_diagnostics_preserve_invalid_proof_and_are_debug_only(self):
        source = PRODUCER.read_text()
        helper = source.split('static func invalidProof(', 1)[1].split('\n    }', 1)[0]
        self.assertIn('@autoclosure () -> String', helper)
        self.assertIn('#if DEBUG', helper)
        self.assertIn('DOLBY_SOURCE_PROOF_REJECT', helper)
        self.assertGreater(helper.index('return .invalidSourceProof'), helper.index('#endif'))
        self.assertNotIn('compressedAudioCompatibilityRequired', helper)

    def test_source_output_timeline_and_framing_rejections_are_distinguishable(self):
        sources = '\n'.join(path.read_text() for path in [PRODUCER, ASSEMBLER, TIMELINE])
        for stage in ['aggregate', 'source.sequence', 'source.nextTimestamp', 'source.input',
                      'source.reinspection', 'output.semantic', 'output.ignored',
                      'timeline.source', 'timeline.claim', 'timeline.planChanged',
                      'timeline.decodeBreak', 'assembler.decodeBreak']:
            self.assertIn(f'invalidProof("{stage}"', sources)
        self.assertIn('stage=assembler.profile', sources)
        self.assertNotIn('throw DolbyAudioSourceFailure.invalidSourceProof', sources)

    def test_diagnostics_do_not_dump_payloads_urls_or_owner_identities(self):
        sources = '\n'.join(path.read_text() for path in [PRODUCER, ASSEMBLER, TIMELINE])
        for expression in ['\\(framed.payload)', '\\(inspected.payload)', '\\(source.extradata)',
                           '\\(descriptor.extradata)', '\\(proof.inputUnit)', '\\(proof.identity)']:
            self.assertNotIn(expression, sources)


if __name__ == '__main__':
    unittest.main()
