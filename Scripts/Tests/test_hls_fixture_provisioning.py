#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt executable shell contracts. All build/network tools are isolated stubs."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('fixture_tools',ROOT/'Scripts/Support/hls_fixture_toolchain.py')
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

class FixtureToolchainContracts(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.repo=self.root/'repository'
        for name in ['Scripts/provision-hls-fixture-toolchain.sh','Scripts/verify-hls-fixture-toolchain.sh',
                     'Scripts/Support/hls_fixture_toolchain.py','Vendor/FFmpeg/ffmpeg.lock.json']:
            target=self.repo/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
        for name in ['Vendor/FFmpeg/configure.flags','Vendor/FFmpeg/Work/.build-lock/owner-pid','Vendor/FFmpeg/Artifacts/app-sentinel']:
            target=self.repo/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text('unchanged')
        self.tools=self.root/'tools';self.tools.mkdir();(self.root/'runner').mkdir()
        self.env={**os.environ,'PATH':str(self.tools)+os.pathsep+os.environ['PATH'],'RUNNER_TEMP':str(self.root/'runner'),
            'MOCK_ROOT':str(self.root),'GITHUB_ENV':str(self.root/'github.env'),'GITHUB_PATH':str(self.root/'github.path')}
        self.command('uname','#!/bin/sh\necho Darwin\n')
        self.command('sysctl','#!/bin/sh\necho 2\n')
        self.command('brew','''#!/bin/sh
if [ "$1" = --prefix ]; then echo "$MOCK_ROOT/brew/$2"; else
 printf 'pkgconf2.5.1\\nx2640.164\\nx2654.1\\nnasm2.16\\n'; fi
''')
        self.command('clang','#!/bin/sh\necho "mock compiler, never native proof"\n')
        self.command('xcrun','''#!/bin/sh
case "$*" in *--find*) echo "$MOCK_ROOT/tools/clang";; *) echo /MockMacOS.sdk;; esac
''')
        self.command('git','''#!/usr/bin/env python3
import os,pathlib,sys
args=sys.argv[1:]
if 'init' in args or 'fetch' in args:pass
elif 'rev-parse' in args:print('c'*40 if '^{tree}' in args[-1] else ('0'*40 if os.environ.get('MOCK_BAD_SHA') else '38b88335f99e76ed89ff3c93f877fdefce736c13'))
elif 'archive' in args:sys.stdout.buffer.write(pathlib.Path(os.environ['MOCK_ROOT'],'source.tar').read_bytes())
elif 'show' in args:print(1700000000)
else:raise SystemExit('unexpected mock git '+repr(args))
''')
        self.command('make','''#!/usr/bin/env python3
import os,pathlib,sys
if '--version' in sys.argv:print('mock GNU Make4.4');raise SystemExit()
if os.environ.get('MOCK_BUILD_FAIL'):raise SystemExit(23)
if 'install' in sys.argv:
 root=pathlib.Path(pathlib.Path('prefix.txt').read_text().strip())/'bin';root.mkdir()
 for tool in ('ffmpeg','ffprobe'):
  path=root/tool;path.write_text('#!/bin/sh\\nprintf "%s\\\\n" "'+tool+' version n8.1.2 fixture-contract-stub"\\n');path.chmod(0o755)
''')
        configure=b'''#!/bin/sh
for arg do case "$arg" in --prefix=*) printf '%s\\n' "${arg#--prefix=}" > prefix.txt;; esac; done
'''
        with tarfile.open(self.root/'source.tar','w') as archive:
            item=tarfile.TarInfo('configure');item.size=len(configure);item.mode=0o755;archive.addfile(item,io.BytesIO(configure))

    def command(self,name,source):
        path=self.tools/name;path.write_text(source);path.chmod(0o755)

    def provision(self,**overrides):
        return subprocess.run([str(self.repo/'Scripts/provision-hls-fixture-toolchain.sh')],cwd=self.repo,
            env={**self.env,**overrides},text=True,capture_output=True,timeout=20)

    def test_source_provenance_and_app_ownership_are_preserved(self):
        result=self.provision();self.assertEqual(result.returncode,0,result.stderr)
        environment=Path(result.stdout.strip());self.assertTrue(environment.is_file())
        install=environment.parent/'install';manifest=json.loads((install/'fixture-toolchain.json').read_text())
        self.assertEqual(manifest['source_commit'],MODULE.COMMIT);self.assertEqual(manifest['source_tag'],'n8.1.2')
        self.assertIn('n8.1.2',manifest['raw_versions']['ffmpeg'])
        self.assertIn('--enable-libx265',manifest['configure_args']);self.assertIn('--disable-network',manifest['configure_args'])
        self.assertTrue(manifest['dependencies']['homebrew'])
        self.assertIn(str(install/'bin/ffmpeg'),(self.root/'github.env').read_text())
        MODULE.verify(install/'bin/ffmpeg',install/'bin/ffprobe',self.repo/'Vendor/FFmpeg/ffmpeg.lock.json')
        for name in ['Vendor/FFmpeg/configure.flags','Vendor/FFmpeg/Work/.build-lock/owner-pid','Vendor/FFmpeg/Artifacts/app-sentinel']:
            self.assertEqual((self.repo/name).read_text(),'unchanged')
        (install/'bin/ffmpeg').write_text('#!/bin/sh\necho "ffmpeg version9.0.2"\n')
        with self.assertRaisesRegex(ValueError,'binary differs'):
            MODULE.verify(install/'bin/ffmpeg',install/'bin/ffprobe',self.repo/'Vendor/FFmpeg/ffmpeg.lock.json')

    def test_wrong_commit_fails_before_build(self):
        result=self.provision(MOCK_BAD_SHA='1');self.assertNotEqual(result.returncode,0)
        self.assertIn('source mismatch',result.stderr)
        self.assertFalse(list((self.root/'runner').glob('*/build/prefix.txt')))

    def test_unreviewed_source_lock_is_rejected(self):
        path=self.repo/'Vendor/FFmpeg/ffmpeg.lock.json';value=json.loads(path.read_text())
        value['sourceURL']='https://unreviewed.invalid/ffmpeg.git';path.write_text(json.dumps(value))
        result=self.provision();self.assertNotEqual(result.returncode,0)
        self.assertIn('source lock differs',result.stderr);self.assertEqual(list((self.root/'runner').iterdir()),[])

    def test_host_build_must_not_overlap_application_work(self):
        result=self.provision(RUNNER_TEMP=str(self.repo/'Vendor/FFmpeg/Work'))
        self.assertNotEqual(result.returncode,0);self.assertIn('outside the application repository',result.stderr)
        self.assertEqual((self.repo/'Vendor/FFmpeg/Work/.build-lock/owner-pid').read_text(),'unchanged')

    def test_failed_build_never_exposes_tools(self):
        result=self.provision(MOCK_BUILD_FAIL='1');self.assertEqual(result.returncode,23,result.stderr)
        self.assertFalse(list((self.root/'runner').glob('*/tools.env')));self.assertFalse((self.root/'github.env').exists())

    def test_only_exact_release_or_tag_spelling_normalizes(self):
        for tool in ['ffmpeg','ffprobe']:
            for version in ['8.1.2','n8.1.2']:
                self.assertEqual(MODULE.normalized_version(f'{tool} version {version} Copyright',tool),'8.1.2')
            for version in ['9.0.2','8.1','8.1.2-modified','n8.1.2-4-g123','8.1.20']:
                with self.assertRaises(ValueError):MODULE.normalized_version(f'{tool} version {version} Copyright',tool)

if __name__=='__main__':unittest.main()
