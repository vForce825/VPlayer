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
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: com.vforce.vplayer\n',app)
        self.assertIn('Sources/VPlayeriOSApp',app)
        for path in ['AppModel.swift','AppDependencies.swift','AppLaunchConfiguration.swift','Player/FullScreenPlayerViewModel.swift','Player/PlaybackPresentationHost.swift']:
            self.assertIn('Sources/VPlayerApp/'+path,app)
        for path in ['VPlayerApp.swift','Views/ChannelBrowserView.swift','Player/FullScreenPlayerView.swift']:
            self.assertNotIn('path: Sources/VPlayerApp/'+path+'\n',app)
    def test_phone_and_tv_share_app_store_identity(self):
        def bundle(target):
            return re.search(r'PRODUCT_BUNDLE_IDENTIFIER: (\S+)', self.target(target)).group(1)
        self.assertEqual(bundle('VPlayeriOS'), bundle('VPlayer'))
        self.assertEqual(bundle('VPlayeriOS'), 'com.vforce.vplayer')
        project=(ROOT/'VPlayer.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('com.vforce.vplayer.ios', project)

    def test_phone_app_icon_is_opaque_1024_square_and_catalogued(self):
        import json
        import struct
        catalog=ROOT/'Sources/VPlayeriOSApp/Resources/Assets.xcassets'
        manifest=catalog/'AppIcon.appiconset/Contents.json'
        self.assertTrue(manifest.is_file(), 'iPhone AppIcon asset is missing')
        contents=json.loads(manifest.read_text())
        images=contents['images']
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]['idiom'], 'universal')
        self.assertEqual(images[0]['platform'], 'ios')
        self.assertEqual(images[0]['size'], '1024x1024')
        data=(catalog/'AppIcon.appiconset'/images[0]['filename']).read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        width,height,depth,color,_,_,_=struct.unpack('>IIBBBBB',data[16:29])
        self.assertEqual((width,height,depth,color), (1024,1024,8,2), 'App Store icon must be 1024-square opaque RGB')
        offset=8
        chunks=[]
        while offset<len(data):
            size=struct.unpack('>I',data[offset:offset+4])[0]
            chunks.append(data[offset+4:offset+8])
            offset+=size+12
        self.assertNotIn(b'tRNS',chunks, 'App Store icon must not use transparency')
        self.assertTrue(b'sRGB' in chunks or b'iCCP' in chunks, 'Icon must declare its color space')
        self.assertIn('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon', self.target('VPlayeriOS'))

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
        for target in ['VPlayerCoreiOS', 'VPlayerPlaybackiOS', 'VPlayeriOS', 'VPlayeriOSTests', 'VPlayeriOSUITests', 'VPlayeriOSBenchmarks']:
            self.assertIn('ARCHS: arm64', self.target(target))
        project=(ROOT/'VPlayer.xcodeproj/project.pbxproj').read_text()
        configurations=re.findall(r'buildSettings = \{(.*?)\n\t\t\t\};', project, re.S)
        phone=[c for c in configurations if 'SDKROOT = iphoneos;' in c]
        self.assertEqual(len(phone), 12)
        for configuration in phone: self.assertIn('ARCHS = arm64;', configuration)
        for target in ['VPlayerCore', 'VPlayerPlayback', 'VPlayer', 'VPlayerTests', 'VPlayerUITests']:
            self.assertNotIn('ARCHS:', self.target(target))

    def test_release_benchmark_compiles_only_independent_video_tests(self):
        benchmark=self.target('VPlayeriOSBenchmarks')
        self.assertIn('Tests/VPlayerTests/Deinterlace/YADIFGoldenPixelTests.swift',benchmark)
        self.assertNotIn('path: Tests/VPlayerTests\n',benchmark)
        self.assertNotIn('target: VPlayeriOS\n',benchmark)
        self.assertIn('TEST_HOST: ""',benchmark)
        workflow=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('-scheme VPlayeriOSBenchmarks',workflow)
        self.assertNotIn('-enableCodeCoverage',workflow)
        self.assertIn('verify-release-artifacts.py verify --sdk iphonesimulator',workflow)
    def test_tv_target_identity_remains_unchanged(self):
        app=self.target('VPlayer')
        self.assertIn('platform: tvOS',app)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: com.vforce.vplayer\n',app)
        self.assertIn('Sources/VPlayerApp/Resources/Info.plist',app)

if __name__=='__main__':unittest.main()
