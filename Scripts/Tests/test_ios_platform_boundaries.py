#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Static platform-boundary checks; native lifecycle behavior is covered by XCTest."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class IOSPlatformBoundaryTests(unittest.TestCase):
    def test_tv_display_apis_are_confined_to_tv_compilation(self):
        source = (ROOT/'Sources/VPlayerPlayback/Rendering/DisplayCriteriaController.swift').read_text()
        self.assertIn('#if os(tvOS)', source)
        self.assertLess(source.index('#if os(tvOS)'), source.index('AVDisplayCriteria'))
        shared = ROOT/'Sources/VPlayerPlayback/Rendering/PlaybackDisplayModeController.swift'
        self.assertTrue(shared.exists(), 'neutral display interface is missing')
        self.assertNotIn('AVDisplayCriteria', shared.read_text())
        context = (ROOT/'Sources/VPlayerPlayback/Rendering/PlaybackPresentationContext.swift').read_text()
        self.assertIn('any PlaybackDisplayModeControlling', context)
        self.assertIn('displayModeFactory', context)

    def test_metal_selects_platform_before_simulator_variant(self):
        source = (ROOT/'Sources/VPlayerPlayback/Media/PlaybackMetalLibrary.swift').read_text()
        self.assertIn('#if os(iOS)', source)
        for resource in ['ios', 'iphonesimulator', 'tvos', 'tvsimulator']:
            self.assertIn('VPlayerPlayback-'+resource+'"', source)

    def test_phone_native_envelope_is_explicit_and_does_not_replace_tv_models(self):
        source = (ROOT/'Sources/VPlayerPlayback/HLS/Native/NativeHLSCapabilities.swift').read_text()
        self.assertIn('enum NativeHLSPlatform', source)
        self.assertIn('evidence.platform == .appleTV', source)
        self.assertIn('evidence.platform == .iPhone', source)
        self.assertIn('["AppleTV6,2", "AppleTV11,1", "AppleTV14,1"]', source)
        self.assertIn('maximumWidth: 1_920', source)
        self.assertIn('maximumWidth: 3_840', source)

    def test_adaptive_processing_uses_shared_admission_and_real_completion(self):
        path=ROOT/'Sources/VPlayerPlayback/ProcessingCPU/GPUVideoProcessingGate.swift'
        self.assertTrue(path.exists(), 'bidirectional GPU admission gate is missing')
        source=path.read_text()
        self.assertIn('DispatchGroup',source)
        self.assertIn('setForeground',source)
        self.assertIn('setPictureInPicture',source)
        for name in ['Deinterlace/YADIF/YADIFProcessor.swift','Scan/LumaScanProbe.swift']:
            source=(ROOT/'Sources/VPlayerPlayback'/name).read_text()
            self.assertIn('waitUntilScheduled()',source)
            self.assertIn('#if os(iOS)',source)

    def test_phone_persistence_does_not_use_tv_cache_policy(self):
        source = (ROOT/'Sources/VPlayerCore/Persistence/VPlayerModelContainer.swift').read_text()
        self.assertIn('#if os(iOS)', source)
        self.assertIn('.applicationSupportDirectory', source)
        self.assertIn('.cachesDirectory', source)

if __name__ == '__main__': unittest.main()
