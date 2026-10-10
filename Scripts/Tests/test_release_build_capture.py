#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Real child-process controls for bounded compiler capture and source provenance."""
from pathlib import Path
import functools
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class ReleaseBuildCaptureTests(unittest.TestCase):
    def module(self):
        path = ROOT / 'Scripts/Support/capture-release-build.py'
        self.assertTrue(path.exists(), 'Compiler capture must bracket the actual native process')
        spec = importlib.util.spec_from_file_location('release_build_capture', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_source_snapshots_bracket_real_child_and_native_failure_is_preserved(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / 'native-finished'
            log = root / 'build.log'
            observed = []
            def snapshot():
                observed.append(marker.exists())
                return {'head': 'fixed-head', 'tree': 'fixed-tree'}
            command = [sys.executable, '-c',
                "import os,sys,time; print('early compiler output',flush=True); "
                "os.close(1); os.close(2); time.sleep(.05); "
                f"open({str(marker)!r},'w').write('done'); sys.exit(7)"]
            with patch.object(module.guard, 'source_snapshot', side_effect=snapshot):
                code = module.capture_command(command, log)
            self.assertEqual(code, 7)
            self.assertEqual(observed, [False, True])
            self.assertEqual(log.read_text(), 'early compiler output\n')
            self.assertEqual(json.loads(Path(str(log)+'.capture.json').read_text())['source'],
                             {'head': 'fixed-head', 'tree': 'fixed-tree'})

    def test_capture_drains_over_limit_child_but_rejects_incomplete_evidence(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'build.log'
            with patch.object(module.guard, 'source_snapshot', return_value={'head': 'head', 'tree': 'tree'}), patch.object(
                    module.guard, 'capture', functools.partial(module.guard.capture, limit=512)):
                code = module.capture_command([sys.executable, '-c', "print('x'*200000)"], log)
            self.assertEqual(code, 1)
            self.assertEqual(log.stat().st_size, 512)
            self.assertTrue(json.loads(Path(str(log)+'.capture.json').read_text())['truncated'])

    def test_tee_preserves_both_native_streams_without_an_extra_log_copy(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'build.log'
            output = io.BytesIO()
            with patch.object(module.guard, 'source_snapshot', return_value={'head': 'head', 'tree': 'tree'}), patch.object(
                    module.sys, 'stdout') as stdout:
                stdout.buffer = output
                code = module.capture_command([sys.executable, '-c',
                    "import os; os.write(1,b'stdout\\n'); os.write(2,b'stderr\\n')"], log, tee=True)
            self.assertEqual(code, 0)
            self.assertEqual(output.getvalue(), b'stdout\nstderr\n')
            self.assertEqual(log.read_bytes(), output.getvalue())
            self.assertEqual(sorted(p.name for p in log.parent.iterdir()), ['build.log', 'build.log.capture.json'])


if __name__ == '__main__':
    unittest.main()
