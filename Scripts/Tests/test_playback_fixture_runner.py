#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise runner argument/plist behavior without requiring Xcode."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/run-playback-integration-tests.sh"


class PlaybackFixtureRunnerTests(unittest.TestCase):
    def run_runner(self, modern=False, status=0):
        with tempfile.TemporaryDirectory(prefix="vplayer runner regression ") as directory:
            root = Path(directory)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            (fixtures / "SHA256SUMS").write_text("fixture\n")
            scratch = root / "scratch"
            scratch.mkdir()
            timeline = root / "timeline 4k.ts"
            timeline.write_bytes(b"fixture")
            target = {"BlueprintName": "VPlayerTests", "EnvironmentVariables": {"KEEP": "yes"}}
            seed = root / "seed.xctestrun"
            document = {"TestConfigurations": [{"TestTargets": [target]}]} if modern else {"VPlayerTests": target}
            seed.write_bytes(plistlib.dumps(document))
            fake = root / "xcodebuild"
            fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, sys, urllib.request
args = sys.argv[1:]
root = pathlib.Path(os.environ["PROBE_ROOT"])
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[0] == "build-for-testing":
    destination = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products"
    destination.mkdir(parents=True)
    shutil.copy(root / "seed.xctestrun", destination / "Fake.xctestrun")
else:
    shutil.copy(args[args.index("-xctestrun") + 1], root / "patched.xctestrun")
    document = plistlib.loads((root / "patched.xctestrun").read_bytes())
    target = (document["TestConfigurations"][0]["TestTargets"][0]
              if "TestConfigurations" in document else document["VPlayerTests"])
    url = target["EnvironmentVariables"]["VPLAYER_TIMELINE_FIXTURE_URL"]
    assert urllib.request.urlopen(url, timeout=5).read() == b"fixture"
    sys.exit(int(os.environ.get("PROBE_STATUS", "0")))
''')
            fake.chmod(0o700)
            env = dict(os.environ, VPLAYER_RUNNER_SELF_TEST_CHILD="1",
                       VPLAYER_RUNNER_FIXTURE_ROOT=str(fixtures),
                       VPLAYER_RUNNER_TEMP_PARENT=str(scratch),
                       VPLAYER_RUNNER_XCODEBUILD=str(fake), PROBE_ROOT=str(root),
                       PROBE_STATUS=str(status))
            selectors = ["VPlayerTests/PlaybackFixtureIntegrationTests", "VPlayerTests/HLSTimelineTests"]
            flags = ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                     "-maximum-test-execution-time-allowance", "300"]
            command = [str(RUNNER), "--timeline-fixture", str(timeline)]
            for selector in selectors:
                command += ["--only-testing", selector]
            result = subprocess.run(command + ["--"] + flags, env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][0], "build-for-testing")
            self.assertNotIn("-test-timeouts-enabled", calls[0])
            self.assertEqual(calls[1][-len(flags):], flags)
            self.assertEqual([arg for arg in calls[1] if arg.startswith("-only-testing:")],
                             ["-only-testing:" + selector for selector in selectors])
            patched = plistlib.loads((root / "patched.xctestrun").read_bytes())
            target = patched["TestConfigurations"][0]["TestTargets"][0] if modern else patched["VPlayerTests"]
            injected = target["EnvironmentVariables"]
            self.assertEqual(injected["KEEP"], "yes")
            self.assertEqual(injected["VPLAYER_TIMELINE_FIXTURE_URL"],
                             injected["VPLAYER_FIXTURE_BASE_URL"] + "/timeline-4k-15m.ts")
            self.assertNotIn("VPLAYER_TIMELINE_FIXTURE_PATH", injected)
            self.assertRegex(injected["VPLAYER_FIXTURE_BASE_URL"], r"^http://127\.0\.0\.1:\d+$")
            self.assertEqual(list(scratch.iterdir()), [], "runner must clean all transient outputs")

    def test_multiple_selectors_timeout_flags_and_fixture_path_reach_legacy_test_target(self):
        self.run_runner()

    def test_modern_xctestrun_target_receives_fixture_environment(self):
        self.run_runner(modern=True)

    def test_test_failure_preserves_exit_status_and_cleans_outputs(self):
        self.run_runner(status=42)


if __name__ == "__main__":
    unittest.main()
