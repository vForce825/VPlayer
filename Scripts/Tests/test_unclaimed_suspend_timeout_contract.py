#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Source ownership guards only; physical cleanup requires the Apple regressions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / 'Sources/VPlayerPlayback/Control/ControlTaskRegistry.swift'


class UnclaimedSuspendTimeoutContractTests(unittest.TestCase):
    def test_only_a_queued_runnerless_stop_transfers_to_retirement(self):
        source = REGISTRY.read_text()
        install = source.split('private func installSuspendTimeout(', 1)[1].split(
            'private func suspendReceiptIsValid(', 1)[0]
        self.assertIn('record.phase == .queued', install)
        self.assertIn('record.payload == nil', install)
        self.assertIn('context.suspend?.task', install)
        self.assertIn('cancel(index)', install)
        self.assertIn('context.suspendRequiresRetirement = true', install)
        self.assertIn('context.suspendPreparedPreserved = false', install)
        self.assertNotIn('context.suspendConfirmed = true', install)
        self.assertLess(install.index('cancel(index)'), install.index('outputContext = context'))

    def test_retirement_still_requires_exact_stop_transfer_and_terminal_work(self):
        source = REGISTRY.read_text()
        complete = source.split('func completeOutputRetirement(', 1)[1].split(
            'func completeOutputTeardown(', 1)[0]
        self.assertIn('context.suspendConfirmed || context.suspendRequiresRetirement', complete)
        self.assertNotIn('|| context.suspendTimedOut', complete)
        self.assertIn('context.suspend?.lifecycle == lifecycle', complete)
        self.assertIn('authority.isTerminal(context.reservation.workGroup)', complete)
        self.assertIn('backend.lifecycle == lifecycle', complete)

    def test_apple_regressions_cover_never_started_and_running_stops(self):
        tests = (ROOT / 'Tests/VPlayerTests/Playback/Control/OutputCleanupCoordinatorTests.swift').read_text()
        self.assertIn('testSuspendTimeoutBeforeClaimTransfersToRetirementWithoutCompletingRunningPrepare', tests)
        self.assertIn('testTimeoutKeepsOriginalStopAndForcedRetirementJoinedUntilLateReceipt', tests)
        integration = (ROOT / 'Tests/VPlayerTests/Playback/HLS/HLSAVPlayerBackendTests.swift').read_text()
        self.assertIn('testProductionHLSStopDuringReplacementPrefixJoinsAfterUnclaimedSuspendTimeout', integration)
        self.assertIn('HLSMediaInformationPrefixGate(bypassingFirstWaits: 1)', integration)
        self.assertIn('task22-progressive-h264-aac-16s.ts', integration)


if __name__ == '__main__':
    unittest.main()
