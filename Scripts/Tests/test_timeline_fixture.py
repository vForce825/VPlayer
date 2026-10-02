#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Real-media validation for the bounded synthetic 4K/15-minute fixture."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Scripts/generate-timeline-fixture.py"


class TimelineFixtureTests(unittest.TestCase):
    def test_subprocess_timeout_terminates_the_child(self):
        spec = importlib.util.spec_from_file_location("timeline_generator", GENERATOR)
        self.assertIsNotNone(spec)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "pid"
            child = [sys.executable, "-c",
                     "import os,pathlib,time; pathlib.Path(" + repr(str(marker)) +
                     ").write_text(str(os.getpid())); time.sleep(60)"]
            with self.assertRaises(subprocess.TimeoutExpired):
                module.run(child, time.monotonic() + 5, 0.5)
            self.assertTrue(marker.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(marker.read_text()), 0)

    def test_generation_signal_cleans_child_and_partial_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "ffmpeg"
            marker = root / "pid"
            fake.write_text("#!/usr/bin/env python3\nimport os,pathlib,time\npathlib.Path(" +
                            repr(str(marker)) + ").write_text(str(os.getpid()))\ntime.sleep(60)\n")
            fake.chmod(0o700)
            process = subprocess.Popen([sys.executable, str(GENERATOR), str(root / "fixture.ts")],
                                       env=dict(os.environ, FFMPEG=str(fake)),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                process.send_signal(signal.SIGTERM)
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 143, stderr)
                self.assertFalse((root / "fixture.ts").exists())
                self.assertEqual(list(root.glob(".vplayer-timeline-*")), [])
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(marker.read_text()), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_generation_preserves_full_4k_duration_and_rejects_shortened_media(self):
        with tempfile.TemporaryDirectory(prefix="vplayer timeline fixture ") as directory:
            root = Path(directory)
            output = root / "timeline 4k 15m.ts"
            command = [sys.executable, str(GENERATOR)]
            generated = subprocess.run(command + [str(output)], capture_output=True, text=True, timeout=310)
            self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
            self.assertLess(output.stat().st_size, 128 * 1024 * 1024)
            self.assertEqual(sorted(path.name for path in root.iterdir()), [output.name])
            verified = subprocess.run(command + ["--verify", str(output)], capture_output=True, text=True, timeout=65)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
            summary = json.loads(verified.stdout)
            self.assertEqual(summary["width"], 3840)
            self.assertEqual(summary["height"], 2160)
            self.assertEqual(summary["video_packets"], 22500)
            self.assertAlmostEqual(summary["video_span_seconds"], 900, places=3)
            self.assertGreaterEqual(summary["audio_span_seconds"], 900)
            self.assertLess(summary["audio_span_seconds"], 900.1)
            # Truncation leaves a decodable TS prefix but cannot satisfy 15-minute coverage.
            shortened = root / "shortened.ts"
            shortened.write_bytes(output.read_bytes()[:188 * 1000])
            rejected = subprocess.run(command + ["--verify", str(shortened)], capture_output=True, text=True, timeout=65)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("duration", rejected.stderr)
            # Existing files are never overwritten, including failed regenerations.
            refused = subprocess.run(command + [str(output)], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("already exists", refused.stderr)


if __name__ == "__main__":
    unittest.main()
