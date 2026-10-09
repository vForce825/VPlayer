#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class IOSPiPContractTests(unittest.TestCase):
    def test_pip_uses_real_sample_and_player_layers_with_public_apis(self):
        path=ROOT/'Sources/VPlayeriOSApp/Player/IOSPictureInPictureCoordinator.swift'
        self.assertTrue(path.exists(),'PiP coordinator is missing')
        text=path.read_text()
        for contract in ['sampleBufferDisplayLayer:', 'playerLayer:', 'requiresLinearPlayback', 'canStartPictureInPictureAutomaticallyFromInline', 'restoreUserInterfaceForPictureInPictureStopWithCompletionHandler']:
            self.assertIn(contract,text)
        self.assertNotIn('setValue(',text)
        self.assertIn('pending?.0 == identity',text, 'Unmount must cancel the matching queued PiP source')
        self.assertIn('PiPCallbackReference',text, 'Controller identity must remain pinned across actor hops')
    def test_root_retains_session_independently_of_cover_visibility(self):
        text=(ROOT/'Sources/VPlayeriOSApp/IOSRootView.swift').read_text()
        self.assertIn('isFullScreenPresented',text)
        self.assertNotIn('.fullScreenCover(item: $session)',text)
    def test_remote_stop_retires_root_session_without_using_view_disappearance(self):
        text=(ROOT/'Sources/VPlayeriOSApp/Player/IOSPlaybackSession.swift').read_text()
        self.assertIn('if model.hasStoppedCurrentRequest { close(); return }',text)
        view=(ROOT/'Sources/VPlayeriOSApp/Player/IOSFullScreenPlayerView.swift').read_text()
        self.assertNotIn('onDisappear { session.close()',view)

    def test_lifecycle_closes_gpu_before_background_and_restores_foreground_policy(self):
        path=ROOT/'Sources/VPlayeriOSApp/Player/IOSVideoProcessingLifecycle.swift'
        self.assertTrue(path.exists(),'synchronous visual lifecycle observer is missing')
        text=path.read_text()
        self.assertIn('willResignActiveNotification',text)
        self.assertIn('didBecomeActiveNotification',text)
        self.assertIn('setForeground(false)',text)
        self.assertIn('setForeground(true)',text)
if __name__=='__main__':unittest.main()
