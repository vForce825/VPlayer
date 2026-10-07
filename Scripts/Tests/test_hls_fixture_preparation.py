#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Rebuilt mode-routing tests use stub generators; no actual media generation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class FixturePreparationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup);self.root=Path(self.temporary.name)
        for name in ['Scripts/prepare-hls-ci-fixtures.sh','Scripts/Support/run-bounded-generation.py']:
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,path)
        self.write('Scripts/verify-hls-fixture-toolchain.sh','#!/bin/sh\nexit 0\n',True)
        self.write('Scripts/generate-playback-fixtures.sh','#!/bin/sh\ntest "$1" = --verify\n',True)
        self.write('Scripts/generate-source-planning-fixtures.sh','''#!/bin/sh
printf 'source %s\\n' "$1" >> calls.log
if [ "$1" = --generate ]; then printf 'fresh synthetic IV' > Tests/Fixtures/SourcePlanning/encrypted-av.mp4; fi
''',True)
        self.write('Scripts/generate-homepod-audio-diagnostic-fixture.py',"from pathlib import Path\nwith Path('calls.log').open('a') as stream:stream.write('diagnostic\\n')\n")
        self.write('Scripts/generate-homepod-large-idr-fixtures.py',"import sys\nfrom pathlib import Path\nassert sys.argv[1:] == ['--verify']\nwith Path('calls.log').open('a') as stream:stream.write('large-idr-verify\\n')\n")
        self.write('Scripts/generate-hls-acceptance-fixture.py',"from pathlib import Path\nwith Path('calls.log').open('a') as stream:stream.write('large360\\n')\n")
        self.write('Tests/Fixtures/SourcePlanning/encrypted-av.mp4','fixed committed synthetic IV')
        self.write('Tests/Fixtures/SourcePlanning/SHA256SUMS','committed fixture manifest')
        self.git('init','-q');self.git('add','.')
        self.git('-c','user.name=fixture-test','-c','user.email=fixture@localhost','commit','-qm','fixture contract')
        self.env={**os.environ,'FFMPEG':'/fixture-only/bin/ffmpeg','FFPROBE':'/fixture-only/bin/ffprobe'}

    def write(self,name,source,executable=False):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(source)
        if executable:path.chmod(0o755)

    def git(self,*args):return subprocess.run(['git',*args],cwd=self.root,check=True,capture_output=True,text=True)
    def run_mode(self,mode):return subprocess.run([str(self.root/'Scripts/prepare-hls-ci-fixtures.sh'),mode],
        cwd=self.root,env=self.env,capture_output=True,text=True,timeout=10)

    def test_final_gates_never_regenerate_committed_source_or_large_fixture(self):
        result=self.run_mode('--verify-committed');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'calls.log').read_text(),'source --verify\nlarge-idr-verify\ndiagnostic\n')
        self.assertEqual((self.root/'Tests/Fixtures/SourcePlanning/encrypted-av.mp4').read_text(),'fixed committed synthetic IV')

    def test_acceptance_alone_adds_large_fixture(self):
        result=self.run_mode('--acceptance');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'calls.log').read_text(),'source --verify\nlarge-idr-verify\ndiagnostic\nlarge360\n')

    def test_readback_alone_regenerates_source_family(self):
        result=self.run_mode('--project-readback');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'calls.log').read_text(),'source --generate\nlarge-idr-verify\ndiagnostic\n')

    def test_final_gates_reject_changed_or_untracked_inputs(self):
        self.write('Tests/Fixtures/SourcePlanning/encrypted-av.mp4','changed local bytes')
        self.assertNotEqual(self.run_mode('--verify-committed').returncode,0)
        self.assertNotIn('diagnostic',(self.root/'calls.log').read_text())
        self.git('checkout','--','Tests/Fixtures/SourcePlanning/encrypted-av.mp4')
        self.write('Tests/Fixtures/SourcePlanning/untracked.mp4','untracked')
        self.assertNotEqual(self.run_mode('--acceptance').returncode,0)
        self.assertNotIn('large360',(self.root/'calls.log').read_text())

if __name__=='__main__':unittest.main()
