#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise runner argument/plist behavior without requiring Xcode."""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/run-playback-integration-tests.sh"


def owned_group_state(group, timeout):
    snapshot = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,state=,command="],
        capture_output=True, text=True, timeout=timeout, check=True)
    return [line for line in snapshot.stdout.splitlines()
            if len(line.split(None, 4)) >= 4 and line.split(None, 4)[2] == str(group)]


def run_probe(command, env, timeout=20):
    # Each probe owns a separate POSIX session. subprocess.run kills only the
    # immediate shell on timeout, leaving its HTTP server holding captured pipes.
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            # Reserve termination/reap time within the unchanged six-second
            # post-failure ceiling; optional ps diagnostics get at most 0.5s.
            cleanup_deadline = time.monotonic() + 6
            stdout = (error.stdout or b"").decode(errors="replace")
            stderr = (error.stderr or b"").decode(errors="replace")
            notes = []
            owned = "unavailable"
            signal_denied = False
            for number in (signal.SIGTERM, signal.SIGKILL):
                try:
                    members = owned_group_state(process.pid, 0.5)
                    live = [line for line in members if not line.split(None, 4)[3].startswith("Z")]
                    if number == signal.SIGTERM:
                        owned = "\n".join(members)
                except (OSError, subprocess.SubprocessError) as snapshot_error:
                    live = None
                    notes.append(f"owned-group state unavailable before signal: {snapshot_error}")
                try:
                    if live:
                        os.killpg(process.pid, number)
                    elif live is None and process.poll() is None:
                        # Popen still owns this exact child even if ps failed.
                        # Do not infer or signal an unverified descendant group.
                        process.send_signal(number)
                except ProcessLookupError:
                    pass
                except PermissionError as signal_error:
                    notes.append(f"owned-process signal was denied: {signal_error}")
                    signal_denied = True
                try:
                    stdout, stderr = process.communicate(
                        timeout=max(0, min(1.5, cleanup_deadline - time.monotonic())))
                except subprocess.TimeoutExpired as drain_error:
                    stdout = (drain_error.stdout or b"").decode(errors="replace")
                    stderr = (drain_error.stderr or b"").decode(errors="replace")
                if signal_denied:
                    break
            # A failed optional snapshot must never strand the directly owned
            # child. No fallback or escalation follows an actual signal denial.
            if not signal_denied and process.poll() is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                except PermissionError as signal_error:
                    notes.append(f"direct-child kill was denied: {signal_error}")
            try:
                process.wait(timeout=max(0, min(1, cleanup_deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                notes.append("direct child could not be reaped within cleanup allowance")
            try:
                stdout, stderr = process.communicate(
                    timeout=max(0, min(0.25, cleanup_deadline - time.monotonic())))
            except subprocess.TimeoutExpired as drain_error:
                stdout = (drain_error.stdout or b"").decode(errors="replace")
                stderr = (drain_error.stderr or b"").decode(errors="replace")
            try:
                while True:
                    remaining = cleanup_deadline - time.monotonic()
                    if remaining <= 0:
                        notes.append("owned-group termination verification exceeded cleanup allowance")
                        break
                    survivors = [line for line in owned_group_state(process.pid, remaining)
                                 if not line.split(None, 4)[3].startswith("Z")]
                    if not survivors:
                        break
                    if remaining < 0.02:
                        notes.append("live owned processes remain: " + "\n".join(survivors))
                        break
                    time.sleep(0.01)
            except (OSError, subprocess.SubprocessError) as snapshot_error:
                notes.append(f"final owned-group state unavailable: {snapshot_error}")
            raise AssertionError(
                f"fixture runner exceeded its unchanged {timeout}s deadline\n"
                f"owned process state at timeout:\n{owned[-8000:]}\n"
                f"cleanup diagnostics: {('; '.join(notes) or 'no live owned processes remain')[-8000:]}\n"
                f"captured stdout:\n{stdout[-8000:]}\n"
                f"captured shell trace/stderr:\n{stderr[-16000:]}"
            ) from error
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        process.stdout.close()
        process.stderr.close()


def stop_marked_child_if_still_owned(marker):
    if not marker.exists():
        return
    pid, group = json.loads(marker.read_text())
    snapshot = subprocess.run(["ps", "-o", "pid=,pgid=", "-p", str(pid)],
                              capture_output=True, text=True, timeout=1)
    if snapshot.stdout.split() == [str(pid), str(group)]:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


class RunnerTimeoutDiagnosticsTests(unittest.TestCase):
    def test_root_exit_during_snapshot_retains_final_stderr(self):
        original_snapshot = owned_group_state
        with tempfile.TemporaryDirectory(prefix="vplayer final output ") as directory:
            release = Path(directory) / "release"
            calls = 0
            def delayed_snapshot(group, timeout):
                nonlocal calls
                calls += 1
                if calls == 1:
                    release.touch()
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        members = original_snapshot(group, max(0.01, deadline - time.monotonic()))
                        if all(line.split(None, 4)[3].startswith("Z") for line in members):
                            return members
                        time.sleep(0.01)
                    raise AssertionError("controlled child did not exit after release")
                return original_snapshot(group, timeout)
            script = r"""
import pathlib, sys, time
print('initial', file=sys.stderr, flush=True)
while not pathlib.Path(sys.argv[1]).exists():
    time.sleep(0.01)
print('late-root-exit', file=sys.stderr, flush=True)
"""
            with patch(__name__ + ".owned_group_state", side_effect=delayed_snapshot):
                with self.assertRaises(AssertionError) as failure:
                    run_probe([sys.executable, "-c", script, str(release)], os.environ.copy(), timeout=0.5)
            captured_stderr = str(failure.exception).split("captured shell trace/stderr:\n", 1)[1]
            self.assertIn("late-root-exit", captured_stderr)

    def test_unavailable_process_snapshot_still_kills_and_reaps_owned_root(self):
        original_popen = subprocess.Popen
        roots = []
        def popen(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            if kwargs.get("start_new_session"):
                roots.append(process)
            return process
        script = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        try:
            with patch("subprocess.Popen", side_effect=popen), \
                 patch(__name__ + ".owned_group_state", side_effect=OSError("ps unavailable")):
                with self.assertRaises(AssertionError) as failure:
                    run_probe([sys.executable, "-c", script], os.environ.copy(), timeout=0.5)
            self.assertEqual(len(roots), 1)
            self.assertIsNotNone(roots[0].poll(), "the directly owned child must be killed and reaped")
            self.assertIn("owned-group state unavailable", str(failure.exception))
        finally:
            for process in roots:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=2)

    def test_cleanup_uses_owned_process_state_when_signal_zero_is_not_permitted(self):
        original_killpg = os.killpg
        def killpg(group, number):
            if number == 0:
                raise PermissionError(1, "signal-zero probe denied for exited group")
            return original_killpg(group, number)
        with patch("os.killpg", side_effect=killpg):
            self.test_timeout_reaps_root_and_retains_latest_output_without_killing_another_group()

    def test_timeout_retains_stage_output_and_stops_owned_descendant(self):
        with tempfile.TemporaryDirectory(prefix="vplayer timeout regression ") as directory:
            marker = Path(directory) / "child.pid"
            script = r"""
import json, os, pathlib, signal, subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
pathlib.Path(sys.argv[1]).write_text(json.dumps([child.pid, os.getpgrp()]))
def stop(_number, _frame):
    child.wait(timeout=2)
    raise SystemExit(143)
signal.signal(signal.SIGTERM, stop)
print("fixture server started", flush=True)
print("waiting for fake xcodebuild", file=sys.stderr, flush=True)
signal.pause()
"""
            cleaned = False
            try:
                with self.assertRaises(AssertionError) as failure:
                    run_probe([sys.executable, "-c", script, str(marker)], os.environ.copy(), timeout=0.5)
                message = str(failure.exception)
                self.assertIn("fixture server started", message)
                self.assertIn("waiting for fake xcodebuild", message)
                self.assertIn("owned process state", message)
                child_pid, _group = json.loads(marker.read_text())
                self.assertIn(str(child_pid), message)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                cleaned = True
            finally:
                if not cleaned:
                    stop_marked_child_if_still_owned(marker)

    def test_timeout_kills_term_ignoring_child_after_parent_and_pipes_exit(self):
        with tempfile.TemporaryDirectory(prefix="vplayer detached pipes ") as directory:
            marker = Path(directory) / "child.pid"
            child_script = (
                "import json,os,pathlib,signal,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "pathlib.Path(" + repr(str(marker)) + ").write_text(json.dumps([os.getpid(),os.getpgrp()])); "
                "time.sleep(60)"
            )
            parent_script = (
                "import subprocess,sys,time; "
                "subprocess.Popen([sys.executable, '-c', sys.argv[1]], "
                "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(60)"
            )
            cleaned = False
            try:
                with self.assertRaises(AssertionError):
                    run_probe([sys.executable, "-c", parent_script, child_script],
                              os.environ.copy(), timeout=0.5)
                self.assertTrue(marker.exists(), "child must establish its TERM-ignore state")
                child_pid, _group = json.loads(marker.read_text())
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    snapshot = subprocess.run(["ps", "-o", "state=", "-p", str(child_pid)],
                                              capture_output=True, text=True, timeout=1)
                    state = snapshot.stdout.strip()
                    if not state or state.startswith("Z"):
                        break
                    time.sleep(0.01)
                self.assertTrue(not state or state.startswith("Z"),
                                f"owned child {child_pid} survived cleanup in state {state}")
                cleaned = True
            finally:
                if not cleaned:
                    stop_marked_child_if_still_owned(marker)


    def test_timeout_reaps_root_and_retains_latest_output_without_killing_another_group(self):
        with tempfile.TemporaryDirectory(prefix="vplayer escaped pipe ") as directory:
            marker = Path(directory) / "child.pid"
            child_script = (
                "import json,os,pathlib,time; "
                "pathlib.Path(" + repr(str(marker)) +
                ").write_text(json.dumps([os.getpid(),os.getpgrp()])); time.sleep(60)"
            )
            parent_script = r"""
import os, signal, subprocess, sys, time
subprocess.Popen([sys.executable, '-c', sys.argv[1]], start_new_session=True)
def stop(_number, _frame):
    print("root-exit-marker", file=sys.stderr, flush=True)
    raise SystemExit(143)
signal.signal(signal.SIGTERM, stop)
print("root=" + str(os.getpid()), flush=True)
time.sleep(60)
"""
            try:
                with self.assertRaises(AssertionError) as failure:
                    run_probe([sys.executable, "-c", parent_script, child_script],
                              os.environ.copy(), timeout=0.5)
                message = str(failure.exception)
                captured_stderr = message.split("captured shell trace/stderr:\n", 1)[1]
                self.assertIn("root-exit-marker", captured_stderr,
                              "must keep output captured after the initial timeout")
                root_pid = int(next(line[5:] for line in message.splitlines() if line.startswith("root=")))
                with self.assertRaises(ProcessLookupError):
                    os.kill(root_pid, 0)
                child_pid, child_group = json.loads(marker.read_text())
                self.assertEqual(child_pid, child_group)
                snapshot = subprocess.run(["ps", "-o", "state=", "-p", str(child_pid)],
                                          capture_output=True, text=True, timeout=1, check=True)
                state = snapshot.stdout.strip()
                self.assertTrue(state and not state.startswith("Z"),
                                "the helper must leave the other session alive, not merely unreaped")
            finally:
                stop_marked_child_if_still_owned(marker)



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
            # Preserve phase evidence on failure without flooding successful CI logs.
            command = ["bash", "-x", str(RUNNER), "--timeline-fixture", str(timeline)]
            for selector in selectors:
                command += ["--only-testing", selector]
            result = run_probe(command + ["--"] + flags, env=env)
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
