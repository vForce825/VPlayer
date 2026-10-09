#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Exercise the real startup script's exit path without an Apple SDK."""
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Scripts/test-release-startup.sh'


class ReleaseStartupDiagnosticsTests(unittest.TestCase):
    def run_build(self, command, *, cancel=False, broken_tee=False, existing_product=False, reused_log=False, guard_status=0):
        # Exercise the actual build invocation, stopping before SDK-dependent
        # artifact inspection. Only the unavailable Apple commands are replaced.
        source = SCRIPT.read_text().split('\napp="$derived_data/')[0]
        boundary = "printf '证据目录：%s\\n构建日志：%s/build.log\\n'"
        self.assertEqual(source.count(boundary), 1)
        initialization, build = source.split(boundary)
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            runner = fixture / 'runner.sh'
            runner.write_text(initialization + r'''
python3() {
    if [[ "$1" == */Support/capture-release-build.py ]]; then
        shift
        command python3 "$BUILD_CAPTURE_TOOL" "$@" || return "$?"
        return "$CAPTURE_STATUS"
    elif [[ "$1" == */verify-release-artifacts.py ]]; then
        shift
        if [[ "$1" == capture ]]; then
            shift
            command python3 "$CAPTURE_TOOL" capture "$@"
        else
            printf 'GUARD_ARG=%s\n' "$@"
            return "$GUARD_STATUS"
        fi
    else
        command python3 "$@"
    fi
}
xcrun() {
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.tvOS-27-0":[{"udid":"build-test-udid","name":"Apple TV 4K (3rd generation)","isAvailable":true,"state":"Booted","dataPath":"/unused-simulator"}]}}'
}
xcodebuild() {
    if [[ "$1" == build ]]; then
        for argument in "$@"; do
            if [[ "$argument" == -enableCodeCoverage ]]; then
                printf 'xcodebuild: error: The flag -enableCodeCoverage is only supported when testing.\n' >&2
                return 64
            fi
        done
    fi
    printf 'selected build stdout\n'
    printf 'selected build stderr\n' >&2
''' + command + '\n}\nexport -f xcodebuild\n' +
                boundary + build + "\nprintf 'BUILD_STAGE_COMPLETE\\n'\n")
            (fixture / 'bin').mkdir()
            native = fixture / 'bin/xcodebuild'
            native.write_text('#!/usr/bin/env bash\nxcodebuild "$@"\n')
            native.chmod(0o755)
            env = {**os.environ, 'TMPDIR': temporary,
                   'PATH': str(fixture / 'bin') + os.pathsep + os.environ['PATH'],
                   'BUILD_CAPTURE_TOOL': str(ROOT / 'Scripts/Support/capture-release-build.py'),
                   'CAPTURE_STATUS': '19' if broken_tee else '0',
                   'TVOS_SIMULATOR_UDID': 'build-test-udid',
                   'CAPTURE_TOOL': str(ROOT / 'Scripts/report-ios-clang-evidence.py'),
                   'GUARD_STATUS': str(guard_status)}
            if existing_product:
                derived = fixture / 'ReleaseStartup'
                app = derived / 'Build/Products/Release-appletvsimulator/VPlayer.app'
                app.mkdir(parents=True)
                (app / 'Info.plist').write_text('existing product is not build approval')
                env['VPLAYER_STARTUP_DERIVED_DATA'] = str(derived)
            if reused_log:
                original = fixture / 'original.log'
                original.write_text('complete fresh compile')
                Path(str(original)+'.release-guard.json').write_text('previous verified inventory')
                env['VPLAYER_STARTUP_BUILD_LOG'] = str(original)
            output = fixture / 'ci.log'
            with output.open('w') as stdout:
                process = subprocess.Popen(['bash', str(runner)], env=env,
                                           stdout=stdout, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                try:
                    if cancel:
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            logs = list(fixture.glob('vplayer-release-startup.*/build.log'))
                            if ('selected build stderr' in output.read_text() and
                                    len(logs) == 1 and
                                    'selected build stderr' in logs[0].read_text()):
                                break
                            if process.poll() is not None:
                                break
                            time.sleep(0.01)
                        # Assert the compiler output reached CI while the build
                        # was still running, rather than only after an exit trap.
                        self.assertIsNone(process.poll())
                        self.assertIn('selected build stderr', output.read_text())
                        self.assertEqual(len(logs), 1)
                        self.assertIn('selected build stderr', logs[0].read_text())
                        os.killpg(process.pid, signal.SIGTERM)
                    _, stderr = process.communicate(timeout=5)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate(timeout=5)
            build_logs = list(fixture.glob('vplayer-release-startup.*/build.log'))
            self.assertEqual(len(build_logs), 0 if existing_product else 1)
            return process.returncode, output.read_text(), stderr, build_logs[0].read_text() if build_logs else ''

    def test_build_enters_bounded_capture_before_starting_native_command(self):
        source=SCRIPT.read_text()
        self.assertIn('capture-release-build.py" --tee --log "$build_log" --',source)
        self.assertNotIn('tee "$evidence/build.log"',source)
        self.assertNotIn('< "$evidence/build.log"',source)
        self.assertLess(source.index('capture-release-build.py'),source.index('xcodebuild build '))

    def test_build_forwards_both_streams_and_keeps_complete_local_log(self):
        status, output, stderr, saved = self.run_build('return 0')
        self.assertEqual(status, 0, stderr)
        self.assertIn('BUILD_STAGE_COMPLETE', output)
        for text in ('selected build stdout', 'selected build stderr'):
            self.assertIn(text, output)
            self.assertIn(text, saved)

    def test_existing_product_without_full_compile_evidence_is_rejected_before_build(self):
        status, output, stderr, _ = self.run_build(
            r'''printf 'BUILD_ARG=%s\n' "$@"; return 65''', existing_product=True)
        self.assertEqual(status, 1)
        self.assertIn('必须使用全新构建目录或已验证的完整构建日志', stderr)
        self.assertNotIn('BUILD_ARG=', output)
        self.assertNotIn('BUILD_STAGE_COMPLETE', output)

    def test_guard_failure_blocks_startup_before_app_inspection(self):
        status, output, stderr, _ = self.run_build('return 0', guard_status=9)
        self.assertEqual(status,1)
        self.assertIn('Release 产物验证失败',stderr)
        self.assertNotIn('BUILD_STAGE_COMPLETE',output)
        self.assertIn('GUARD_ARG=verify',output)
        self.assertIn('GUARD_ARG=appletvsimulator',output)

    def test_existing_verified_compile_is_rechecked_without_rebuilding(self):
        status, output, stderr, _ = self.run_build(
            r'''printf 'BUILD_ARG=%s\n' "$@"; return 65''', existing_product=True, reused_log=True)
        self.assertEqual(status,0,stderr)
        self.assertNotIn('BUILD_ARG=',output)
        self.assertIn('GUARD_ARG=verify',output)
        self.assertIn('GUARD_ARG=--build-log',output)
        self.assertIn('original.log',output)
        self.assertIn('BUILD_STAGE_COMPLETE',output)

    def test_fresh_build_uses_selected_architecture_without_swift_coverage(self):
        status, output, stderr, _ = self.run_build(
            r'''printf 'BUILD_ARG=%s\n' "$@"; return 0''')
        self.assertEqual(status, 0, stderr)
        args = [line.removeprefix('BUILD_ARG=') for line in output.splitlines()
                if line.startswith('BUILD_ARG=')]
        self.assertEqual(args[args.index('-configuration') + 1], 'Release')
        self.assertEqual(args[args.index('-destination') + 1],
                         'platform=tvOS Simulator,id=build-test-udid')
        self.assertIn('ONLY_ACTIVE_ARCH=YES', args)
        # The committed Release defaults and scheme must disable coverage.
        # Command-line overrides would hide a regression in those defaults.
        self.assertNotIn('-enableCodeCoverage', args)
        self.assertFalse(any('COVERAGE=' in arg for arg in args))
        scheme_name = args[args.index('-scheme') + 1]
        self.assertEqual(scheme_name, 'VPlayerReleaseStartupTests')
        schemes = ROOT / 'VPlayer.xcodeproj/xcshareddata/xcschemes'
        scheme = ET.parse(schemes / f'{scheme_name}.xcscheme').getroot()
        self.assertEqual(scheme.find('TestAction').get('codeCoverageEnabled', 'NO'), 'NO')
        self.assertIsNone(scheme.find('TestAction/TestPlans'))
        for action in ('TestAction', 'LaunchAction', 'ProfileAction',
                       'AnalyzeAction', 'ArchiveAction'):
            self.assertEqual(scheme.find(action).get('buildConfiguration'), 'Release')
        running = [entry.find('BuildableReference').attrib for entry in
                   scheme.findall('BuildAction/BuildActionEntries/BuildActionEntry')
                   if entry.get('buildForRunning') == 'YES']
        main = ET.parse(schemes / 'VPlayer.xcscheme').getroot()
        self.assertEqual(running, [entry.find('BuildableReference').attrib for entry in
                         main.findall('BuildAction/BuildActionEntries/BuildActionEntry')
                         if entry.get('buildForRunning') == 'YES'])
        self.assertCountEqual([entry['BlueprintName'] for entry in running],
                              ['VPlayer', 'VPlayerCore', 'VPlayerPlayback'])
        ui_test = scheme.find("BuildAction/BuildActionEntries/BuildActionEntry/"
                              "BuildableReference[@BlueprintName='VPlayerUITests']/..")
        self.assertIsNotNone(ui_test)
        self.assertEqual(ui_test.get('buildForTesting'), 'YES')
        for action in ('Running', 'Profiling', 'Archiving', 'Analyzing'):
            self.assertEqual(ui_test.get(f'buildFor{action}'), 'NO')
        self.assertFalse(any(arg.startswith(('ENABLE_TESTABILITY=',
                                            'SWIFT_OPTIMIZATION_LEVEL=',
                                            'SWIFT_COMPILATION_MODE=', 'ARCHS='))
                             for arg in args))
        self.assertIn('BUILD_STAGE_COMPLETE', output)

    def test_build_failure_is_not_masked_by_successful_log_forwarding(self):
        status, output, stderr, saved = self.run_build('return 65')
        self.assertEqual(status, 1)
        self.assertIn('模拟器构建失败', stderr)
        self.assertNotIn('BUILD_STAGE_COMPLETE', output)
        self.assertIn('selected build stderr', output)
        self.assertIn('selected build stderr', saved)

    def test_cancelled_build_has_already_forwarded_its_diagnostics(self):
        status, output, _, saved = self.run_build('sleep 30', cancel=True)
        self.assertEqual(status, 143)
        self.assertNotIn('BUILD_STAGE_COMPLETE', output)
        self.assertIn('selected build stderr', saved)

    def test_log_write_failure_does_not_allow_trials_to_continue(self):
        status, output, stderr, _ = self.run_build('return 0', broken_tee=True)
        self.assertEqual(status, 1)
        self.assertIn('模拟器构建失败', stderr)
        self.assertNotIn('BUILD_STAGE_COMPLETE', output)

    def test_six_cold_launches_keep_both_modes_and_four_liveness_checks(self):
        # Execute the real trial loop and cleanup. Only simulator/process tools
        # are replaced; their calls are the observable contract of this script.
        source = SCRIPT.read_text()
        preamble = source.split("printf '证据目录：%s\\n构建日志：%s/build.log\\n'")[0]
        trials = 'for mode in normal step1; do' + source.split(
            'for mode in normal step1; do', 1)[1]
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            runner = fixture / 'runner.sh'
            runner.write_text(preamble + r'''
simulator_udid=verified-test-udid
bundle_id=example.exact.test.app
simulator_data_path="$evidence/simulator"
probe="$evidence/probe.dylib"
xcrun() {
    [[ "$1" == simctl ]] || return 90
    shift
    case "$1" in
        terminate)
            printf 'terminate:%s:%s\n' "$2" "$3" >> "$TRIAL_CALLS"
            ;;
        launch)
            printf 'launch:%s:%s:%s:%s\n' "$4" "$5" "$mode" "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES-}" >> "$TRIAL_CALLS"
            [[ "$2" == --stdout=* && "$3" == --stderr=* ]] || return 91
            mkdir -p "$(dirname "$simulator_data_path${2#--stdout=}")"
            printf 'app stdout\n' > "$simulator_data_path${2#--stdout=}"
            if [[ "${SIMCTL_CHILD_DYLD_INSERT_LIBRARIES-}" == "$probe" ]]; then
                printf '仅模拟 tvOS xzone step1 计费取整\n' > "$simulator_data_path${3#--stderr=}"
            else
                : > "$simulator_data_path${3#--stderr=}"
            fi
            printf '%s: 123\n' "$5"
            ;;
        spawn)
            [[ "$3 $4" == 'launchctl list' ]] || return 92
            printf 'service:%s\n' "$2" >> "$TRIAL_CALLS"
            printf '123 0 UIKitApplication:%s[123]\n' "$bundle_id"
            ;;
        *) return 93 ;;
    esac
}
sleep() { printf 'sleep:%s\n' "$*" >> "$TRIAL_CALLS"; }
kill() { printf 'kill:%s\n' "$*" >> "$TRIAL_CALLS"; }
ps() {
    printf 'ps:%s\n' "$*" >> "$TRIAL_CALLS"
    if [[ "$4" == stat= ]]; then printf 'S\n'; else printf '123 S 00:01 VPlayer\n'; fi
}
''' + trials)
            calls = fixture / 'calls.log'
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('SIMCTL_CHILD_')}
            result = subprocess.run(['bash', str(runner)],
                                    env={**env, 'TMPDIR': temporary, 'TRIAL_CALLS': str(calls)},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            entries = calls.read_text().splitlines()
            launches = [line for line in entries if line.startswith('launch:')]
            self.assertEqual(len(launches), 6)
            self.assertEqual(launches[:3], [
                'launch:verified-test-udid:example.exact.test.app:normal:'] * 3)
            for launch in launches[3:]:
                self.assertTrue(launch.startswith(
                    'launch:verified-test-udid:example.exact.test.app:step1:'))
                self.assertTrue(launch.endswith('/probe.dylib'))
            self.assertEqual(entries.count(
                'terminate:verified-test-udid:example.exact.test.app'), 7)
            self.assertEqual(entries.count('sleep:1'), 24)
            self.assertEqual(entries.count('kill:-0 123'), 24)
            self.assertEqual(entries.count('ps:-p 123 -o stat='), 24)
            self.assertEqual(entries.count('service:verified-test-udid'), 24)
            self.assertIn('通过：六次冷启动均持续存活', result.stdout)

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
