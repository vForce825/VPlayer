#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]

class IOSTargetStructureTests(unittest.TestCase):
    def target(self,name):
        targets=(ROOT/'project.yml').read_text().split('targets:',1)[1].split('schemes:',1)[0]
        match=re.search(r'^  '+name+r':\n(.*?)(?=^  \w|\Z)',targets,re.M|re.S)
        self.assertIsNotNone(match, name+' target is missing')
        return match.group(1)
    def test_phone_targets_preserve_module_identity(self):
        for name,module in [('VPlayerCoreiOS','VPlayerCore'),('VPlayerPlaybackiOS','VPlayerPlayback')]:
            source=self.target(name)
            self.assertIn('platform: iOS',source)
            self.assertIn('deploymentTarget: "27.0"',source)
            self.assertIn('PRODUCT_NAME: '+module,source)
            self.assertIn('PRODUCT_MODULE_NAME: '+module,source)
        self.assertIn('Vendor/FFmpeg/Artifacts-iOS/FFmpeg.xcframework',self.target('VPlayerPlaybackiOS'))
    def test_phone_app_has_separate_entry_and_explicit_shared_models(self):
        app=self.target('VPlayeriOS')
        self.assertIn('TARGETED_DEVICE_FAMILY: "1"',app)
        self.assertIn('com.vforce.vplayer.ios',app)
        self.assertIn('Sources/VPlayeriOSApp',app)
        for path in ['AppModel.swift','AppDependencies.swift','AppLaunchConfiguration.swift','Player/FullScreenPlayerViewModel.swift','Player/PlaybackPresentationHost.swift']:
            self.assertIn('Sources/VPlayerApp/'+path,app)
        for path in ['VPlayerApp.swift','Views/ChannelBrowserView.swift','Player/FullScreenPlayerView.swift']:
            self.assertNotIn('path: Sources/VPlayerApp/'+path+'\n',app)
    def test_phone_declares_audio_background_and_portrait_landscape(self):
        import plistlib
        path=ROOT/'Sources/VPlayeriOSApp/Resources/Info.plist'
        self.assertTrue(path.exists(),'phone Info.plist is missing')
        info=plistlib.loads(path.read_bytes())
        self.assertIn('audio',info['UIBackgroundModes'])
        self.assertNotIn('TVTopShelfImage',info)
        self.assertEqual(set(info['UISupportedInterfaceOrientations']),{'UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'})
    def test_product_metadata_and_runnable_match_build_settings(self):
        for target, product in [('VPlayerCoreiOS', 'VPlayerCore'), ('VPlayerPlaybackiOS', 'VPlayerPlayback'), ('VPlayeriOS', 'VPlayer')]:
            self.assertIn('productName: '+product, self.target(target))
        project=(ROOT/'VPlayer.xcodeproj/project.pbxproj').read_text()
        for stale in ['path = VPlayerCoreiOS.framework;', 'path = VPlayerPlaybackiOS.framework;', 'path = VPlayeriOS.app;']:
            self.assertFalse(stale in project, stale)
        import xml.etree.ElementTree as ET
        scheme=ET.parse(ROOT/'VPlayer.xcodeproj/xcshareddata/xcschemes/VPlayeriOS.xcscheme')
        runnable=scheme.find('./LaunchAction/BuildableProductRunnable/BuildableReference')
        self.assertIsNotNone(runnable, 'Run must launch the iPhone app, not expand a framework')
        self.assertEqual(runnable.attrib['BlueprintName'], 'VPlayeriOS')
        self.assertEqual(runnable.attrib['BuildableName'], 'VPlayer.app')

    def test_ios_architectures_match_the_audited_arm64_profile_only(self):
        for target in ['VPlayerCoreiOS', 'VPlayerPlaybackiOS', 'VPlayeriOS', 'VPlayeriOSTests', 'VPlayeriOSUITests']:
            self.assertIn('ARCHS: arm64', self.target(target))
        project=(ROOT/'VPlayer.xcodeproj/project.pbxproj').read_text()
        configurations=re.findall(r'buildSettings = \{(.*?)\n\t\t\t\};', project, re.S)
        phone=[c for c in configurations if 'SDKROOT = iphoneos;' in c]
        self.assertEqual(len(phone), 10)
        for configuration in phone: self.assertIn('ARCHS = arm64;', configuration)
        for target in ['VPlayerCore', 'VPlayerPlayback', 'VPlayer', 'VPlayerTests', 'VPlayerUITests']:
            self.assertNotIn('ARCHS:', self.target(target))

    def test_tv_target_identity_remains_unchanged(self):
        app=self.target('VPlayer')
        self.assertIn('platform: tvOS',app)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: com.vforce.vplayer\n',app)
        self.assertIn('Sources/VPlayerApp/Resources/Info.plist',app)

if __name__=='__main__':unittest.main()
