#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Explicit readback allowlists reject unrelated files and symlinks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('readback',ROOT/'Scripts/Support/export-hls-generation.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReadbackTests(unittest.TestCase):
    def test_exact_inventory_rejects_extras_and_symlinks(self):
        self.assertTrue({'hevc-sdr.mp4','hevc-hlg.mp4','encrypted-aac.mp4','encrypted-av.mp4',
            'aac-lc.adts','aac-implicit-sbr-signaling.adts','large-au.ts','large-au.mp4',
            'large-au-limit.mp4','large-au-over-limit.mp4'}<=module.SOURCE_FILES)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/'Tests/Fixtures/SourcePlanning';source.mkdir(parents=True)
            schemes=root/'VPlayer.xcodeproj/xcshareddata/xcschemes';schemes.mkdir(parents=True)
            for name in module.SOURCE_FILES:(source/name).write_text('public synthetic contract')
            for name in module.SCHEMES:(schemes/name).write_text('generated contract')
            (root/'VPlayer.xcodeproj/project.pbxproj').write_text('generated')
            (root/'VPlayerHLSAcceptance.xctestplan').write_text('generated')
            self.assertEqual(len(module.collect_files(root)),len(module.SOURCE_FILES)+len(module.SCHEMES)+2)
            extra=source/'private-notes.txt';extra.write_text('never export')
            with self.assertRaisesRegex(ValueError,'inventory'):module.collect_files(root)
            extra.unlink();allowed=source/'hevc-sdr.mp4';allowed.unlink();allowed.symlink_to(source/'hevc-hlg.mp4')
            with self.assertRaisesRegex(ValueError,'regular'):module.collect_files(root)

if __name__=='__main__':unittest.main()
