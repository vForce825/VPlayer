#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise the real startup script's exit path without an Apple SDK."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Scripts/test-release-startup.sh'


class ReleaseStartupDiagnosticsTests(unittest.TestCase):
    def test_live_startup_establishes_add_focus_before_selecting(self):
        source = (ROOT / 'Tests/VPlayerUITests/LiveStartupUITests.swift').read_text()
        activation = source.split('let add = app.buttons["source.add"]', 1)[1]
        before_select, after_select = activation.split('XCUIRemote.shared.press(.select)', 1)
        self.assertIn('for _ in 0..<4 where !add.hasFocus', before_select)
        self.assertIn('XCUIRemote.shared.press(.down)', before_select)
        self.assertIn(r'guard add.wait(for: \.hasFocus, toEqual: true, timeout: 2) else {',
                      before_select)
        self.assertIn('XCTFail(', before_select)
        self.assertIn('return', before_select)
        for identifier in ('name', 'm3u', 'epg', 'save'):
            self.assertIn(f'source.editor.{identifier}', after_select)

    def run_exit(self, command, *, selected=True, broken_copy=False):
        # Load the actual initialization, functions and traps, stopping immediately
        # before the first SDK operation. No production test mode is required.
        source = SCRIPT.read_text()
        boundary = "printf '证据目录：%s\\n构建日志：%s/build.log\\n'"
        self.assertEqual(source.count(boundary), 1)
        preamble = source.split(boundary)[0]
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            runner = fixture / 'runner.sh'
            runner.write_text(preamble + r'''
exec 3>&2
simulator_udid=verified-test-udid
bundle_id=example.exact.test.app
simulator_data_path="$evidence/simulator"
prefix="$evidence/step1-1"
mkdir -p "$(dirname "$simulator_data_path$prefix")"
printf 'selected launch PID 123\n' > "$prefix.launch.log"
printf 'selected stdout\n' > "$simulator_data_path$prefix.stdout.log"
python3 -c 'print("X" * 20000)' >> "$simulator_data_path$prefix.stdout.log"
printf 'selected stderr assertion total=4352 cap=4096\n' > "$simulator_data_path$prefix.stderr.log"
printf 'unrelated previous attempt\n' > "$evidence/normal-3.stderr.log"
# Simulate termination making the process-owned streams unavailable. The
# selected process evidence must already have been copied and printed.
xcrun() {
    printf 'termination:%s\n' "$*" >&3
    rm -f "$simulator_data_path$prefix.stdout.log" "$simulator_data_path$prefix.stderr.log"
}
''' + ('cp() { return 7; }\n' if broken_copy else '') +
                ('launched=1\n' if selected else 'prefix=""\n') + command + '\n')
            return subprocess.run(['bash', str(runner)], env={**os.environ, 'TMPDIR': temporary},
                                  capture_output=True, text=True, timeout=5)

    def test_failure_emits_only_selected_bounded_streams_before_termination(self):
        result = self.run_exit("fail 'simulated early exit'")
        self.assertEqual(result.returncode, 1)
        self.assertIn('selected launch PID 123', result.stderr)
        self.assertIn('selected stdout', result.stderr)
        self.assertIn('selected stderr assertion total=4352 cap=4096', result.stderr)
        self.assertNotIn('unrelated previous attempt', result.stderr)
        self.assertLessEqual(result.stderr.count('X'), 8192)
        self.assertLess(result.stderr.index('selected stderr assertion'),
                        result.stderr.index('termination:'))
        self.assertIn('termination:simctl terminate verified-test-udid example.exact.test.app', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_success_does_not_print_process_streams(self):
        result = self.run_exit('exit 0')
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('selected stdout', result.stderr)
        self.assertNotIn('selected stderr', result.stderr)

    def test_signals_keep_exit_status_and_selected_evidence(self):
        for signal, status in [('INT', 130), ('TERM', 143)]:
            with self.subTest(signal=signal):
                result = self.run_exit(f'kill -s {signal} $$')
                self.assertEqual(result.returncode, status)
                self.assertIn('selected stderr assertion', result.stderr)

    def test_copy_failure_does_not_mask_failure_or_skip_termination(self):
        result = self.run_exit('exit 143', broken_copy=True)
        self.assertEqual(result.returncode, 143)
        self.assertIn('termination:simctl terminate verified-test-udid example.exact.test.app', result.stderr)

    def test_prelaunch_failure_does_not_print_another_attempt(self):
        result = self.run_exit("fail 'no process launched'", selected=False)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('selected stdout', result.stderr)
        self.assertNotIn('selected stderr', result.stderr)
        self.assertNotIn('termination:', result.stderr)


if __name__ == '__main__':
    unittest.main()
