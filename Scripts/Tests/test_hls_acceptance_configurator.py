#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise the actual xctestrun configurator against real temporary product paths."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]

class ConfiguratorTests(unittest.TestCase):
    def test_preserves_products_manifest_and_resolves_every_testroot_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            derived=Path(temporary)/'DerivedData'
            products=derived/'Build/Products'
            bundle=products/'Debug-appletvsimulator/VPlayerHLSAcceptanceTests.xctest'
            framework=products/'Debug-appletvsimulator/VPlayerPlayback.framework'
            libraries=products/'Debug-appletvsimulator'
            bundle.mkdir(parents=True); framework.mkdir()
            target={'BlueprintName':'VPlayerHLSAcceptanceTests',
                'TestBundlePath':'__TESTROOT__/Debug-appletvsimulator/VPlayerHLSAcceptanceTests.xctest',
                'DependentProductPaths':['__TESTROOT__/Debug-appletvsimulator/VPlayerPlayback.framework'],
                'TestingEnvironmentVariables':{'DYLD_LIBRARY_PATH':'__TESTROOT__/Debug-appletvsimulator',
                    'DYLD_FRAMEWORK_PATH':'__TESTROOT__/Debug-appletvsimulator'},
                'EnvironmentVariables':{'PRESERVE_ME':'unchanged'}}
            manifest=products/'VPlayer_FiveMinute.xctestrun'
            with manifest.open('wb') as stream:
                plistlib.dump({'TestConfigurations':[{'Name':'FiveMinute','TestTargets':[target]}]},stream)
            run=subprocess.run(['python3',str(ROOT/'Scripts/Support/configure-hls-acceptance.py'),
                str(derived),'a'*40,'b'*40,'c'*64,'candidate',''],cwd=ROOT,text=True,capture_output=True,check=True)
            self.assertEqual(run.stdout.strip(),str(manifest))
            self.assertFalse((Path(temporary)/'acceptance.xctestrun').exists())
            with manifest.open('rb') as stream: configured=plistlib.load(stream)['TestConfigurations'][0]['TestTargets'][0]
            paths=[configured['TestBundlePath'],*configured['DependentProductPaths'],
                *configured['TestingEnvironmentVariables'].values()]
            for path in paths:
                self.assertTrue(Path(path.replace('__TESTROOT__',str(manifest.parent))).exists(),path)
            self.assertEqual(configured['EnvironmentVariables']['HLS_ACCEPTANCE_HEAD'],'a'*40)
            self.assertEqual(configured['EnvironmentVariables']['PRESERVE_ME'],'unchanged')
            self.assertEqual(configured['TestingEnvironmentVariables'],target['TestingEnvironmentVariables'])

if __name__=='__main__': unittest.main()
