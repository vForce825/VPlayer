#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Offline manifest contract tests. Temporary dummy files are not media evidence."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('manifest',ROOT/'Scripts/Support/source_fixture_manifest.py')
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

class SourceManifestContracts(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.fixtures=self.root/'Tests/Fixtures/SourcePlanning';self.fixtures.mkdir(parents=True)
        for name in MODULE.EXPECTED-{'SHA256SUMS','provenance.json'}:
            (self.fixtures/name).write_bytes(('offline contract only: '+name).encode())
        self.tools='PINNED_FIXTURE_TOOLS='+json.dumps(dict(source_commit=MODULE.COMMIT,source_tree='c'*40,
            raw_versions={'ffmpeg':'ffmpeg version8.1.2 contract','ffprobe':'ffprobe version8.1.2 contract'}))
        # Keep version-token spacing identical to the real verified tool record.
        self.tools=self.tools.replace('version8.1.2','version 8.1.2')
        self.he=dict(encoder='Apple Core Audio afconvert',codec='aach',container='adts',observed_profile='HE-AAC',
            decoded_rate=48000,adts_core_rate=24000,decoded_frames=96000,
            encoded_sha256=MODULE.digest(self.fixtures/'aac-implicit-sbr-signaling.adts'),
            afconvert_binary_sha256='d'*64,macos_version='contract-only',macos_build='contract-only',
            command=['/usr/bin/afconvert','-f','adts','-d','aach@48000'])
        self.he['initial_window']=dict(access_units=8,bytes=120,observed_profile='HE-AAC',
            decoded_rate=48000,adts_core_rate=24000,decoded_frames=16384,decoded_channels=2)

    def test_finalize_and_offline_verify_detect_changed_or_extra_file(self):
        MODULE.finalize(self.fixtures,self.tools,json.dumps(self.he))
        self.assertEqual(MODULE.verify(self.fixtures)['ffmpeg_source_commit'],MODULE.COMMIT)
        path=self.fixtures/'video-high.ts';old=path.read_bytes();path.write_bytes(old+b'changed')
        with self.assertRaisesRegex(ValueError,'hash mismatch'):MODULE.verify(self.fixtures)
        path.write_bytes(old);(self.fixtures/'extra.txt').write_text('not allowed')
        with self.assertRaisesRegex(ValueError,'inventory'):MODULE.verify(self.fixtures)

    def test_lc_provenance_cannot_be_frozen_as_genuine_sbr(self):
        self.he['observed_profile']='LC'
        with self.assertRaisesRegex(ValueError,'HE/SBR'):MODULE.finalize(self.fixtures,self.tools,json.dumps(self.he))

    def test_unobserved_initial_window_cannot_be_frozen(self):
        del self.he['initial_window']
        with self.assertRaisesRegex(ValueError,'initial.*window'):MODULE.finalize(self.fixtures,self.tools,json.dumps(self.he))

    def test_actual_verify_shell_needs_no_encoder_or_network(self):
        MODULE.finalize(self.fixtures,self.tools,json.dumps(self.he))
        for name in ['Scripts/generate-source-planning-fixtures.sh','Scripts/Support/source_fixture_manifest.py',
                     'Scripts/Support/export-hls-generation.py']:
            target=self.root/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
        subprocess.run(['git','init','-q'],cwd=self.root,check=True)
        result=subprocess.run([str(self.root/'Scripts/generate-source-planning-fixtures.sh'),'--verify'],cwd=self.root,
            env={**os.environ,'FFMPEG':'/missing/encoder','FFPROBE':'/missing/probe','PYTHONDONTWRITEBYTECODE':'1'},
            capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('verified offline',result.stdout)

if __name__=='__main__':unittest.main()
