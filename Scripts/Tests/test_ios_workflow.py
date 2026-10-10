#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
from pathlib import Path
import json
import hashlib
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
ROOT=Path(__file__).resolve().parents[2]
class IOSWorkflowTests(unittest.TestCase):
    def workflow_step(self, name):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        marker='      - name: '+name+'\n'
        self.assertIn(marker,text)
        return text.split(marker,1)[1].split('      - name:',1)[0]
    def step_allows(self, step, outcomes):
        expression=re.search(r'^        if: (.+)$',step,re.MULTILINE).group(1)
        for clause in expression.split(' && '):
            if clause in ('always()','!cancelled()'):
                continue
            match=re.fullmatch(r"steps\.(\w+)\.outcome == 'success'",clause)
            self.assertIsNotNone(match,'Unexpected acceptance condition: '+clause)
            if outcomes.get(match.group(1)) != 'success':
                return False
        return True
    def test_separate_workflow_preserves_exact_head_and_no_push_trigger(self):
        path=ROOT/'.github/workflows/ios-ci.yml'
        self.assertTrue(path.exists(),'iOS native validation workflow is missing')
        text=path.read_text()
        self.assertIn('pull_request:',text);self.assertIn('workflow_dispatch:',text)
        self.assertNotIn('push:',text)
        self.assertIn('github.event.pull_request.head.sha || github.sha',text)
        self.assertIn('--platform ios',text)
        self.assertIn('generic/platform=iOS',text)
        self.assertIn('Scripts/test-ios.sh',text)
        self.assertIn('needs_refresh',text)
        self.assertIn('contents: read',text)
    def test_short_generation_readback_gates_expensive_native_acceptance(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('  generated-inputs:',text)
        self.assertIn('needs: [generated-inputs, diagnostic-probe]',text)
        self.assertIn("needs.generated-inputs.outputs.needs_refresh == 'false'",text)
        self.assertIn("if: steps.generated.outputs.needs_refresh == 'true'",text)
        self.assertLess(text.index('name: Fail closed until generated outputs are committed'),
                        text.index('  ios-tests:'))
        self.assertEqual(text.count('xcodegen generate --spec project.yml'),1)
    def test_native_configurations_are_independent_but_still_fail_the_job(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('id: prepare', text)
        self.assertIn('id: simulator', text)
        guard="if: always() && !cancelled() && steps.prepare.outcome == 'success' && steps.simulator.outcome == 'success'"
        self.assertEqual(text.count(guard), 5)
        self.assertNotIn("steps.release_build", text)
        self.assertNotIn("--build-only", text)
        self.assertNotIn('continue-on-error', text.split('  ios-tests:',1)[1])
    def test_generation_budget_is_reserved_for_pinned_inputs_and_cold_start_is_local(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        generation,native=text.split('  ios-tests:',1)
        self.assertIn('timeout-minutes: 15',generation)
        self.assertNotIn('boot_probe',generation)
        self.assertNotIn('BOOT_PROBE',generation)
        self.assertNotIn('--boot-only',generation)
        self.assertNotIn('continue-on-error',generation)
        self.assertIn('XcodeGen@2.44.1',generation)
        self.assertIn("if: steps.generated.outputs.needs_refresh == 'true'",generation)
        self.assertIn('exit 1',generation)
        self.assertIn('needs: [generated-inputs, diagnostic-probe]',native)
        self.assertIn("needs.generated-inputs.outputs.needs_refresh == 'false'",native)
        self.assertNotIn('Verify Release simulator cold starts without fixture bypass',native)
        self.assertNotIn('iOS-RunnerControl',native)
        self.assertNotIn('steps.release_build',native)
        outcomes={key:'success' for key in ('prepare','simulator','regression_preflight','regression_preflight_report','fixtures')}
        for name in ('Preflight PiP retirement and playlist deletion regressions','Prepare mandatory synthetic shared-playback fixtures','Run shared playback and iPhone touch tests'):
            self.assertTrue(self.step_allows(self.workflow_step(name),outcomes))
        self.assertTrue((ROOT/'Scripts/Support/ios-startup-runner.py').is_file())
        self.assertTrue((ROOT/'Tests/VPlayeriOSUITests/IOSReleaseStartupTests.swift').is_file())
        self.assertIn('ios-startup-runner.py',native)
    def test_shared_fixtures_and_release_measurement_are_required(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('prepare-hls-ci-fixtures.sh --verify-committed',text)
        self.assertIn("steps.fixtures.outcome == 'success'",text)
        self.assertIn('synthetic-hlg50-ac3-64s.ts',text)
        self.assertIn('-configuration Release ENABLE_TESTABILITY=YES',text)
        self.assertIn('-only-testing:VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUYADIFBenchmark',text)
        self.assertIn('-only-testing:VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testCPUAdapterMatchesEveryPinnedNV12AndP010FieldExactly',text)
        self.assertEqual(text.count('Scripts/report-ios-test-status.py'),3)
    def test_preflight_runs_exact_failed_cases_with_shared_debug_build_and_preserves_stderr_exit(self):
        step=self.workflow_step('Preflight PiP retirement and playlist deletion regressions')
        self.assertIn('id: regression_preflight',step)
        self.assertIn('timeout-minutes: 20',step)
        self.assertNotIn('continue-on-error',step)
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        self.assertIn('set -o pipefail',script)
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'Scripts').mkdir()
            native=directory/'Scripts/test-ios.sh'
            native.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS_LOG"\nprintf "native stdout\\n"\nprintf "IOS_PIP_RETIREMENT_STAGE=before_install\\n" >&2\nexit "$NATIVE_EXIT"\n')
            native.chmod(0o755)
            args_log=directory/'args'
            expected=['-configuration','Debug','-derivedDataPath',str(directory/'iOS-Simulator'),
                '-resultBundlePath',str(directory/'iOS-Regressions.xcresult'),'-parallel-testing-enabled','NO',
                '-collect-test-diagnostics','never','-test-timeouts-enabled','YES',
                '-default-test-execution-time-allowance','120','-maximum-test-execution-time-allowance','300',
                '-only-testing:VPlayeriOSTests/IOSPictureInPictureCoordinatorTests/testRetirementBeforeQueuedNativeStopCannotLeaveForegroundOnCPU',
                '-only-testing:VPlayeriOSUITests/IOSLibraryFlowTests/testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation']
            for code in [0,7]:
                run=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=directory,
                    env=dict(os.environ,RUNNER_TEMP=str(directory),ARGS_LOG=str(args_log),NATIVE_EXIT=str(code)),
                    capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,code,run.stderr)
                self.assertEqual(args_log.read_text().splitlines(),expected)
                self.assertIn('native stdout',run.stdout)
                self.assertIn('IOS_PIP_RETIREMENT_STAGE=before_install',run.stdout)
                self.assertEqual((directory/'iOS-Regressions.log').read_text(),run.stdout)
    def test_preflight_failure_blocks_expensive_steps_but_success_still_requires_full_suite(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        fixtures=self.workflow_step('Prepare mandatory synthetic shared-playback fixtures')
        full=self.workflow_step('Run shared playback and iPhone touch tests')
        report=self.workflow_step('Report PiP retirement and playlist deletion preflight')
        self.assertIn('id: regression_preflight_report',report)
        self.assertIn('if: always()',report)
        self.assertNotIn('continue-on-error',report)
        outcomes={key:'success' for key in ('prepare','simulator','regression_preflight','regression_preflight_report','fixtures')}
        for step in (fixtures,full):
            self.assertTrue(self.step_allows(step,outcomes))
            for failed in ('regression_preflight','regression_preflight_report'):
                for outcome in ('failure','cancelled','skipped'):
                    self.assertFalse(self.step_allows(step,dict(outcomes,**{failed:outcome})),
                        f'{failed}={outcome} must block fixtures and full testing')
        self.assertLess(text.index('Preflight PiP retirement'),text.index('Prepare mandatory synthetic'))
        self.assertLess(text.index('Report PiP retirement'),text.index('Prepare mandatory synthetic'))
        self.assertNotIn('-only-testing:',full)
        self.assertNotIn('continue-on-error',full)
        self.assertIn('Scripts/test-ios.sh -configuration Debug',full)
        full_report=self.workflow_step('Report functional test results')
        self.assertIn('report-ios-test-status.py "$RUNNER_TEMP/iOS.xcresult" || status=1',full_report)
        self.assertNotIn('--preflight',full_report)
    def test_preflight_report_preserves_failures_and_only_summarizes_bounded_fixed_stage_markers(self):
        step=self.workflow_step('Report PiP retirement and playlist deletion preflight')
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'bin').mkdir()
            reporter=directory/'bin/python3'
            reporter.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$REPORT_ARGS_LOG"\ncase "$1" in\nScripts/report-xcresult-failures.py) exit "$FAILURE_REPORT_EXIT" ;;\nScripts/report-ios-test-status.py) exit "$STATUS_REPORT_EXIT" ;;\n*) exit 99 ;;\nesac\n')
            reporter.chmod(0o755)
            marker='IOS_PIP_RETIREMENT_STAGE=retire.before-initial-install'
            private='must-not-publish'
            (directory/'iOS-Regressions.log').write_text('\n'.join([
                private,'IOS_PIP_RETIREMENT_STAGE=retire.'+private,
                marker+' '+private,'IOS_PIP_RETIREMENT_STAGE='+('x'*10000),
                'native stderr '+private,*([marker]*45)])+'\n')
            for failure_code,status_code in [(0,0),(1,0),(0,1)]:
                summary=directory/'summary';summary.write_text('existing summary\n')
                args_log=directory/'report-args';args_log.write_text('')
                run=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=directory,
                    env=dict(os.environ,PATH=str(directory/'bin')+os.pathsep+os.environ['PATH'],
                        RUNNER_TEMP=str(directory),GITHUB_STEP_SUMMARY=str(summary),
                        REPORT_ARGS_LOG=str(args_log),FAILURE_REPORT_EXIT=str(failure_code),
                        STATUS_REPORT_EXIT=str(status_code)),capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,int(bool(failure_code or status_code)),run.stderr)
                self.assertEqual(args_log.read_text().splitlines(),[
                    f'Scripts/report-xcresult-failures.py {directory}/iOS-Regressions.xcresult',
                    f'Scripts/report-ios-test-status.py {directory}/iOS-Regressions.xcresult --preflight'])
                lines=summary.read_text().splitlines()
                self.assertEqual(lines,['existing summary']+[marker]*30)
                self.assertTrue(all(len(line)<=240 for line in lines[1:]))
                self.assertNotIn(private,summary.read_text())
    def install_guard_fixture(self, directory):
        # The artifact guard has its own native/portable controls. Here only
        # replace unavailable Apple artifact inspection, retaining real capture.
        (directory/'Scripts/verify-release-artifacts.py').write_text(
            'import os,runpy,sys\n'
            'if sys.argv[1] == "verify": sys.exit(int(os.environ.get("GUARD_EXIT", "0")))\n'
            + 'runpy.run_path(' + repr(str(ROOT/'Scripts/report-ios-clang-evidence.py'))
            + ',run_name="__main__")\n')

    def run_cpu_measurement(self, native_exit=0, settings_mode='normal', guard_exit=0):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        step=text.split('name: Measure optimized CPU processing without device qualification',1)[1].split('      - name:',1)[0]
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'bin').mkdir();(directory/'Scripts').mkdir()
            self.install_guard_fixture(directory)
            native=directory/'bin/xcodebuild'
            native.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json,os,sys
                args=sys.argv[1:]
                with open(os.environ['XCODE_ARGS_LOG'],'a') as stream:
                    stream.write(json.dumps(args)+'\\n')
                if '-showBuildSettings' in args:
                    if '-enableCodeCoverage' in args:
                        print('The flag -enableCodeCoverage is only supported when testing.',file=sys.stderr)
                        sys.exit(64)
                    if os.environ['SETTINGS_MODE']=='query_failed': sys.exit(65)
                    target=args[args.index('-target')+1] if '-target' in args else 'VPlayeriOSBenchmarks'
                    row={'target':target,'buildSettings':{'GCC_OPTIMIZATION_LEVEL':'s',
                        'OTHER_CFLAGS':'-DPRIVATE=must-not-publish','SWIFT_OPTIMIZATION_LEVEL':'-O','ENABLE_TESTABILITY':'YES',
                        'PRIVATE_SOURCE':'must-not-publish'}}
                    rows=[row,{'target':'VPlayerCoreiOS','buildSettings':{'GCC_OPTIMIZATION_LEVEL':'0'}}]
                    if os.environ['SETTINGS_MODE']=='missing': rows=[]
                    if os.environ['SETTINGS_MODE']=='duplicate': rows.append(row)
                    print(json.dumps(rows))
                    sys.exit(0)
                print('IOS_CPU_YADIF_BENCH width=1920 height=1080 depth=8 pair_ms=[1.0]')
                print('native stderr',file=sys.stderr)
                sys.exit(int(os.environ['NATIVE_EXIT']))
                '''))
            native.chmod(0o755)
            args_log=directory/'args'
            run=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=directory,
                env=dict(os.environ,PATH=str(directory/'bin')+os.pathsep+os.environ['PATH'],
                    RUNNER_TEMP=str(directory),IOS_TEST_DESTINATION='platform=iOS Simulator,id=unit-test',
                    XCODE_ARGS_LOG=str(args_log),NATIVE_EXIT=str(native_exit),SETTINGS_MODE=settings_mode,GUARD_EXIT=str(guard_exit)),
                capture_output=True,text=True,timeout=3)
            calls=[json.loads(line) for line in args_log.read_text().splitlines()]
            log=directory/'iOS-CPU-Release.log'
            return run,calls,log.read_text() if log.exists() else None
    def test_cpu_settings_query_reaches_production_target_and_preserves_native_test_exit(self):
        for code in [0,7]:
            with self.subTest(native_exit=code):
                run,calls,log=self.run_cpu_measurement(native_exit=code)
                self.assertEqual(run.returncode,code,run.stderr)
                self.assertEqual(len(calls),2)
                query,native=calls
                self.assertEqual(query[query.index('-target')+1],'VPlayerPlaybackiOS')
                self.assertEqual(query[query.index('-sdk')+1],'iphonesimulator')
                self.assertNotIn('-destination',query)
                self.assertIn('ARCHS=arm64',query)
                self.assertFalse(any('COVERAGE' in arg for arg in query))
                self.assertNotIn('-enableCodeCoverage',query)
                for args in calls:
                    self.assertEqual(args[args.index('-configuration')+1],'Release')
                    self.assertIn('ENABLE_TESTABILITY=YES',args)
                    self.assertIn('CODE_SIGNING_ALLOWED=NO',args)
                self.assertEqual(native[:5],['test','-project','VPlayer.xcodeproj','-scheme','VPlayeriOSBenchmarks'])
                self.assertNotIn('-enableCodeCoverage',native)
                self.assertEqual(native[native.index('-default-test-execution-time-allowance')+1],'120')
                self.assertEqual(native[native.index('-maximum-test-execution-time-allowance')+1],'300')
                self.assertEqual(sum(arg.startswith('-only-testing:') for arg in native),3)
                lines=[line for line in run.stdout.splitlines() if line.startswith('IOS_CPU_BUILD_SETTINGS=')]
                self.assertEqual(len(lines),1)
                self.assertEqual(json.loads(lines[0].split('=',1)[1]),{'GCC_OPTIMIZATION_LEVEL':'s',
                    'SWIFT_OPTIMIZATION_LEVEL':'-O','ENABLE_TESTABILITY':'YES'})
                self.assertNotIn('must-not-publish',run.stdout+run.stderr)
                self.assertIn('IOS_CPU_YADIF_BENCH width=1920',log)
                self.assertIn('native stderr',log)
    def test_successful_native_benchmark_does_not_mask_artifact_guard_failure(self):
        run,calls,log=self.run_cpu_measurement(guard_exit=9)
        self.assertEqual(run.returncode,9,run.stderr)
        self.assertEqual(len(calls),2)
        self.assertIn('native stderr',log)

    def test_cpu_settings_diagnostic_failure_cannot_block_native_measurement_or_dump_settings(self):
        for mode in ['missing','duplicate','query_failed']:
            with self.subTest(settings_mode=mode):
                run,calls,log=self.run_cpu_measurement(native_exit=7,settings_mode=mode)
                self.assertEqual(run.returncode,7,'Diagnostics must preserve the native test outcome')
                self.assertEqual(len(calls),2,'Missing diagnostic evidence cannot prevent the native test')
                reason='query_failed' if mode=='query_failed' else 'expected_one_playback_target'
                self.assertIn('IOS_CPU_BUILD_SETTINGS_UNVERIFIED='+reason,run.stdout)
                self.assertNotIn('IOS_CPU_BUILD_SETTINGS=',run.stdout)
                self.assertNotIn('Traceback',run.stderr)
                self.assertNotIn('must-not-publish',run.stdout+run.stderr)
                self.assertIn('IOS_CPU_YADIF_BENCH width=1920',log)
    def test_device_build_log_capture_preserves_native_failures_and_icon_acceptance(self):
        step=self.workflow_step('Compile Release for a physical iPhone destination without signing')
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        self.assertIn('set -o pipefail',script)
        self.assertIn('tee /dev/stderr',script)
        self.assertIn("IOS_APP_IDENTITY_AND_ICON=passed",script)
        script=script.split("python3 - <<'PYICON'",1)[0]
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'bin').mkdir();(directory/'Scripts').mkdir()
            self.install_guard_fixture(directory)
            native=directory/'bin/xcodebuild'
            native.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS_LOG"\nprintf "native stdout\\n"\nprintf "native stderr\\n" >&2\nexit "$NATIVE_EXIT"\n')
            native.chmod(0o755)
            args_log=directory/'args'
            for code in [0,7]:
                run=subprocess.run(['bash','-e','-o','pipefail','-c',script],cwd=directory,
                    env=dict(os.environ,PATH=str(directory/'bin')+os.pathsep+os.environ['PATH'],
                        RUNNER_TEMP=str(directory),ARGS_LOG=str(args_log),NATIVE_EXIT=str(code)),
                    capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,code,run.stderr)
                args=args_log.read_text().splitlines()
                self.assertEqual(args[args.index('-configuration')+1],'Release')
                self.assertEqual(args[args.index('-destination')+1],'generic/platform=iOS')
                self.assertEqual(args[args.index('-derivedDataPath')+1],str(directory/'iOS-Device'))
                self.assertEqual((directory/'iOS-Device.log').read_text(),'native stdout\nnative stderr\n')
                self.assertEqual(run.stderr,'native stdout\nnative stderr\n')
    def test_compiler_evidence_uses_exact_build_roots_and_always_reports_advisory_uncertainty(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        for name,sdk,root in [
                ('Report physical destination Release C compiler evidence','iphoneos','iOS-Device'),
                ('Report CPU measurement and qualification limits','iphonesimulator','iOS-CPU-Release')]:
            step=self.workflow_step(name)
            self.assertIn('if: always()',step)
            self.assertIn('xcrun --find clang',step)
            self.assertIn('xcrun clang --version',step)
            self.assertIn('report-ios-clang-evidence.py report',step)
            self.assertIn('--sdk '+sdk,step)
            self.assertIn('--log "$RUNNER_TEMP/'+root+'.log"',step)
            self.assertIn('--derived-data "$RUNNER_TEMP/'+root+'"',step)
            self.assertIn('tee -a "$GITHUB_STEP_SUMMARY"',step)
            self.assertNotIn('upload-artifact',step)
        self.assertIn('python3 Scripts/Tests/test_ios_clang_evidence.py',text)
        self.assertIn('python3 Scripts/Tests/test_cpu_worker_service_contract.py',text)
        measure=self.workflow_step('Measure optimized CPU processing without device qualification')
        self.assertIn('set -o pipefail',measure)
        self.assertIn('verify-release-artifacts.py capture --log "$RUNNER_TEMP/iOS-CPU-Release.log"',measure)
        self.assertNotIn('NEON',measure)
        self.assertIn('-only-testing:VPlayeriOSBenchmarks/YADIFGoldenPixelTests/testPlaybackDiagnosticPolicyExcludesSignpostsFromShippingRelease',measure)
    def test_cpu_benchmark_summary_only_accepts_bounded_complete_numeric_rows(self):
        step=self.workflow_step('Report CPU measurement and qualification limits')
        self.assertIn("<<'PYBENCH'",step)
        body=textwrap.dedent(step.split("<<'PYBENCH'",1)[1].split("\n",1)[1].split('          PYBENCH',1)[0])
        def original(width,height,depth):
            return f'IOS_CPU_YADIF_BENCH width={width} height={height} depth={depth} workers=4 setup_ms=1.0 output_ms=2.0 warmup_ms=3.0 pair_ms=[1.0, 2.0, 3.0, 4.0, 5.0] environment=simulator-not-iphone-hardware configuration=release'
        original_rows=[original(w,h,d) for w,h in [(1920,1080),(3840,2160)] for d in [8,10]]
        private='must-not-publish'
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'benchmark.log'
            noise=[private, original_rows[0]+' '+private, original_rows[0].replace('workers=4','workers=0'),
                original_rows[0].replace('width=1920','width=1280'), 'x'*10000]
            def capture(text):
                log.write_text(text)
                Path(str(log)+'.capture.json').write_text(json.dumps({'complete':True,'truncated':False,
                    'bytes':log.stat().st_size,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()}))
            capture('\n'.join(noise+original_rows)+'\n')
            run=subprocess.run(['python3','-c',body,str(log)],capture_output=True,text=True,timeout=3)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertEqual(run.stdout.splitlines(),original_rows+['IOS_CPU_BENCHMARK_SUMMARY=verified cases=4'])
            self.assertNotIn(private,run.stdout)
            self.assertLess(len(run.stdout),10000)
            state=Path(str(log)+'.capture.json')
            state.write_text(json.dumps({'complete':True,'truncated':True,'bytes':log.stat().st_size,
                'sha256':hashlib.sha256(log.read_bytes()).hexdigest()}))
            truncated=subprocess.run(['python3','-c',body,str(log)],capture_output=True,text=True,timeout=3)
            self.assertEqual(truncated.returncode,0,truncated.stderr)
            self.assertNotIn('SUMMARY=verified',truncated.stdout)
            self.assertIn('SUMMARY=unverified',truncated.stdout)
            capture('\n'.join(original_rows[:-1]+[original_rows[0]]*50)+'\n')
            run=subprocess.run(['python3','-c',body,str(log)],capture_output=True,text=True,timeout=3)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertEqual(len(run.stdout.splitlines()),4)
            self.assertIn('IOS_CPU_BENCHMARK_SUMMARY=unverified cases=3 duplicate=true',run.stdout)
    def test_functional_results_are_reported_before_independent_cpu_measurement(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('name: Report functional test results',text)
        first=text.split('name: Report functional test results',1)[1].split('      - name:',1)[0]
        self.assertIn('if: always()',first)
        self.assertIn('report-xcresult-failures.py "$RUNNER_TEMP/iOS.xcresult" || status=1',first)
        self.assertNotIn('iOS-RunnerControl',first)
        self.assertNotIn('iOS-Release.xcresult',first)
        self.assertNotIn('iOS-CPU-Release',first)
        self.assertIn('report-ios-test-status.py "$RUNNER_TEMP/iOS.xcresult" || status=1',first)
        self.assertIn('exit "$status"',first)
        self.assertLess(text.index('Run shared playback and iPhone touch tests'),text.index('Report functional test results'))
        self.assertLess(text.index('Report functional test results'),text.index('Measure optimized CPU processing'))
        self.assertIn('name: Report CPU measurement and qualification limits',text)
        cpu=text.split('name: Report CPU measurement and qualification limits',1)[1]
        self.assertLess(text.index('Measure optimized CPU processing'),text.index('Report CPU measurement and qualification limits'))
        self.assertIn('if: always()',cpu)
        self.assertIn('report-xcresult-failures.py "$RUNNER_TEMP/iOS-CPU-Release.xcresult" || status=1',cpu)
        self.assertIn('--benchmark || status=1',cpu)
        self.assertIn('exit "$status"',cpu)
        self.assertNotIn('iOS-RunnerControl',cpu)
        self.assertEqual(text.count('PHYSICAL_IPHONE_PIP_AUDIO_THERMAL_AND_HANDOFF_QUALIFICATION=not_run'),1)
    def test_pip_relay_is_debug_only_and_preserves_native_exit_and_arguments(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('python3 Scripts/Tests/test_ios_pip_runtime_report.py',text)
        step=text.split('name: Run shared playback and iPhone touch tests',1)[1].split('      - name:',1)[0]
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        relay='python3 Scripts/report-ios-pip-runtime.py --candidate "$CANDIDATE_SHA"'
        self.assertIn('set -o pipefail',script)
        self.assertIn('2>&1 |',script)
        self.assertIn('swift Scripts/report-host-audio-control.swift',script)
        self.assertEqual(text.count(relay),1)
        self.assertIn(relay,script)
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'Scripts').mkdir();(directory/'bin').mkdir()
            native=directory/'Scripts/test-ios.sh'
            native.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS_LOG"\nprintf "native output\\n"\nexit "$NATIVE_EXIT"\n')
            native.chmod(0o755)
            host=directory/'bin/swift'
            host.write_text('#!/bin/bash\nexit "$HOST_EXIT"\n')
            host.chmod(0o755)
            observer=directory/'bin/python3'
            observer.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$RELAY_ARGS_LOG"\ncat\nexit "$RELAY_EXIT"\n')
            observer.chmod(0o755)
            args_log=directory/'args';relay_args_log=directory/'relay-args'
            expected=['-configuration','Debug','-derivedDataPath',str(directory/'iOS-Simulator'),
                '-resultBundlePath',str(directory/'iOS.xcresult'),'-parallel-testing-enabled','NO',
                '-collect-test-diagnostics','never','-test-timeouts-enabled','YES',
                '-default-test-execution-time-allowance','120','-maximum-test-execution-time-allowance','300']
            for code,host_code,relay_code in [(n,h,r) for n in [0,7] for h in [0,9] for r in [0,11]]:
                run=subprocess.run(['bash','-e','-c',script],cwd=directory,env=dict(os.environ,
                    PATH=str(directory/'bin')+os.pathsep+os.environ['PATH'],RUNNER_TEMP=str(directory),
                    CANDIDATE_SHA='a'*40,ARGS_LOG=str(args_log),RELAY_ARGS_LOG=str(relay_args_log),
                    NATIVE_EXIT=str(code),HOST_EXIT=str(host_code),RELAY_EXIT=str(relay_code)),capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,relay_code or code,run.stderr)
                diagnostic = '' if host_code == 0 else 'HOST_AUDIO_CONTROL outcome=unverified reason=diagnostic_process_failed qualification=host-control-not-ios-acceptance\n'
                self.assertEqual(run.stdout,diagnostic+'native output\n')
                self.assertEqual(args_log.read_text().splitlines(),expected)
                self.assertEqual(relay_args_log.read_text().splitlines(),['Scripts/report-ios-pip-runtime.py','--candidate','a'*40])
if __name__=='__main__':unittest.main()
