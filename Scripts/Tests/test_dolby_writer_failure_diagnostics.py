#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Diagnostic wiring guards only; actual native failure localization requires Apple CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRITER = (ROOT / 'Sources/VPlayerPlayback/HLS/SegmentedFMP4Writer.swift').read_text()
BRANCH = (ROOT / 'Sources/VPlayerPlayback/HLS/DolbyCompressedAudioRenditionBranch.swift').read_text()


class DolbyWriterFailureDiagnosticTests(unittest.TestCase):
    def test_diagnostic_helper_preserves_failure_classification(self):
        self.assertTrue('static func diagnosedSystemFailure(' in WRITER)
        helper = WRITER.split('static func diagnosedSystemFailure(', 1)[1].split('\n    }', 1)[0]
        self.assertIn('StaticString = #function', helper)
        self.assertIn('UInt = #line', helper)
        self.assertIn('status: OSStatus? = nil', helper)
        self.assertIn('#if DEBUG', helper)
        self.assertIn('HLS_WRITER_SYSTEM_FAILURE', helper)
        self.assertGreater(helper.index('return .systemFailure'), helper.index('#endif'))
        self.assertNotIn('compressedAudioCompatibilityRequired', helper)
        self.assertNotIn('unsupportedCompressedAudioFormat', helper)

    def test_distinct_internal_failure_boundaries_remain_fail_closed(self):
        for stage in ['callback.writerIdentity', 'callback.type', 'callback.pending',
                      'callback.provenance', 'callback.fragmentSequence',
                      'callback.publication', 'callback.discarded', 'callback.relay',
                      'callback.seal', 'compressed.sampleBuffer']:
            self.assertTrue(f'diagnosedSystemFailure("{stage}"' in WRITER, stage)
        callback = WRITER.split('func receiveSystemSegment(', 2)[2].split(
            'func makeAACEffectiveEndpointReceipt(', 1)[0]
        self.assertIn('capsule.consume(', callback)
        self.assertIn('cadenceIsValid', callback)
        self.assertIn('actual.sequence == expected.partialValue', callback)
        self.assertIn('try segmentEvidence.retireVerified(', callback)

    def test_successful_flush_preserves_the_reentrant_callback_failure(self):
        body = WRITER.split('private func flushIfRequiredIsolated(', 1)[1].split(
            'private func discardUnusedFlushAdmissionIsolated(', 1)[0]
        state_guard = body.split('guard state == .started else', 1)[1].split('}', 1)[0]
        self.assertTrue('throw systemFailureIsolated("flush.state")' in state_guard,
                        'successful native flush can still synchronously retire the outer writer')
        self.assertNotIn('diagnosedSystemFailure', state_guard,
                         'never overwrite an already validated layout rejection with a new generic failure')

    def test_first_error_priority_is_unchanged(self):
        helper = WRITER.split('private func systemFailureIsolated(', 1)[1].split('\n    }', 1)[0]
        self.assertLess(helper.index('if let firstTypedCallbackFailure'),
                        helper.index('if firstSystemFailureDiagnostic == nil'))
        self.assertLess(helper.index('if firstSystemFailureDiagnostic == nil'),
                        helper.index('return .systemError(diagnostic)'))
        self.assertTrue('return .diagnosedSystemFailure(' in helper)
        self.assertLess(helper.index('return .systemError(diagnostic)'),
                        helper.index('return .diagnosedSystemFailure('))

    def test_owned_codec_trials_are_independent_xctest_cases(self):
        smoke = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeOwnedDolbyFallbackSmokeTests.swift').read_text()
        for codec, label in [('ac3', 'AC3'), ('eac3', 'EAC3')]:
            name = f'testActual{label}WriterTrialEitherPublishesCompressedOrJoinsOwnedAACRetry'
            self.assertTrue(f'func {name}()' in smoke, name)
            body = smoke.split(f'func {name}()', 1)[1].split('\n    }', 1)[0]
            self.assertIn(f'try await assertActualWriterTrial(codec: .{codec})', body)
        self.assertNotIn('for codec in [', smoke,
                         'an AC3 failure must not prevent the EAC3 source proof and native trial from running')

    def test_smoke_does_not_report_a_released_backend_as_zero_attempts(self):
        smoke = (ROOT / 'Tests/VPlayerTests/Playback/HLS/NativeOwnedDolbyFallbackSmokeTests.swift').read_text()
        self.assertIn('nativeTotal=\\(native.nativeWriterCount)', smoke)
        self.assertNotIn('generatedBundleCallsForTesting ?? 0', smoke)
        self.assertIn('?? "unavailable"', smoke)
        self.assertIn('private weak var created:', smoke)

    def test_branch_failure_is_bounded_and_precedes_retirement(self):
        body = BRANCH.split('func append(_ timed:', 1)[1].split('private func collect(', 1)[0]
        self.assertTrue('DOLBY_BRANCH_FAILURE' in body)
        self.assertIn('sourceMask=', body)
        self.assertIn('rawSystemFailure=', body)
        self.assertLess(body.index('DOLBY_BRANCH_FAILURE'), body.index('await writer.cancelAwaitingCompletion()'))
        for forbidden in ['\\(error)', '\\(timed)', '\\(firstProof)', '\\(unit.payload)']:
            self.assertNotIn(forbidden, body)


if __name__ == '__main__':
    unittest.main()
