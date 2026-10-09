#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
from pathlib import Path
import json
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
        self.assertIn('needs: generated-inputs',text)
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
        self.assertEqual(text.count(guard), 6)
        self.assertIn("steps.release_build.outcome == 'success'", text)
        self.assertIn("--build-only", text)
        self.assertNotIn('continue-on-error', text.split('  ios-tests:',1)[1])
    def test_fast_boot_probe_precedes_generation_and_cannot_relax_acceptance(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        generation,native=text.split('  ios-tests:',1)
        self.assertIn('id: boot_probe',generation)
        probe=generation.split('id: boot_probe',1)[1].split('      - name:',1)[0]
        self.assertIn('timeout-minutes: 5',probe)
        self.assertIn('continue-on-error: true',probe)
        self.assertIn('ios-startup-runner.py --boot-only',probe)
        self.assertLess(generation.index('--boot-only'),generation.index('brew install mint'))
        self.assertEqual(generation.count('continue-on-error: true'),1)
        for marker in ['IOS_BOOT_PROBE_HEAD','IOS_BOOT_PROBE_TREE','IOS_BOOT_PROBE_IMAGE','IOS_BOOT_PROBE_IMAGE_VERSION','IOS_BOOT_PROBE_APP_AND_XCTEST=not_run']:
            self.assertIn(marker,generation)
        self.assertIn('steps.boot_probe.outcome',generation)
        self.assertIn('GITHUB_STEP_SUMMARY',generation)
        self.assertIn('boot_ready_only',generation)
        self.assertNotIn('boot_probe',native)
        self.assertIn('Verify Release simulator cold starts without fixture bypass',native)
        self.assertIn('needs.generated-inputs.outputs.needs_refresh',native)
    def test_probe_summary_classifies_raw_outcome_without_claiming_app_pass(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('name: Record diagnostic cold boot outcome',text)
        step=text.split('name: Record diagnostic cold boot outcome',1)[1].split('      - name:',1)[0]
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        with tempfile.TemporaryDirectory() as directory:
            for outcome,expected in [('success','boot_ready_only'),('failure','failed'),('skipped','unverified')]:
                path=Path(directory)/outcome
                run=subprocess.run(['bash','-e','-c',script],env=dict(os.environ,PROBE_OUTCOME=outcome,GITHUB_STEP_SUMMARY=str(path)),capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertIn('IOS_BOOT_PROBE_STEP_OUTCOME='+outcome,run.stdout)
                self.assertIn('IOS_BOOT_PROBE_CLASSIFICATION='+expected,run.stdout)
                self.assertIn('App and XCTest were not run',path.read_text())
                self.assertLess(path.stat().st_size,512)
    def test_shared_fixtures_and_release_measurement_are_required(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('prepare-hls-ci-fixtures.sh --verify-committed',text)
        self.assertIn("steps.fixtures.outcome == 'success'",text)
        self.assertIn('synthetic-hlg50-ac3-64s.ts',text)
        self.assertIn('-configuration Release ENABLE_TESTABILITY=YES -enableCodeCoverage NO',text)
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
        full_report=self.workflow_step('Report startup and functional test results')
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
    def run_cpu_measurement(self, native_exit=0, settings_mode='normal'):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        step=text.split('name: Measure optimized CPU processing without device qualification',1)[1].split('      - name:',1)[0]
        script=textwrap.dedent(step.split('        run: |\n',1)[1])
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'bin').mkdir()
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
                        'OTHER_CFLAGS':'','SWIFT_OPTIMIZATION_LEVEL':'-O','ENABLE_TESTABILITY':'YES',
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
                    XCODE_ARGS_LOG=str(args_log),NATIVE_EXIT=str(native_exit),SETTINGS_MODE=settings_mode),
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
                self.assertIn('CLANG_ENABLE_CODE_COVERAGE=NO',query)
                self.assertNotIn('-enableCodeCoverage',query)
                for args in calls:
                    self.assertEqual(args[args.index('-configuration')+1],'Release')
                    self.assertIn('ENABLE_TESTABILITY=YES',args)
                    self.assertIn('CODE_SIGNING_ALLOWED=NO',args)
                self.assertEqual(native[:5],['test','-project','VPlayer.xcodeproj','-scheme','VPlayeriOSBenchmarks'])
                self.assertEqual(native[native.index('-enableCodeCoverage')+1],'NO')
                self.assertEqual(native[native.index('-default-test-execution-time-allowance')+1],'120')
                self.assertEqual(native[native.index('-maximum-test-execution-time-allowance')+1],'300')
                self.assertEqual(sum(arg.startswith('-only-testing:') for arg in native),2)
                lines=[line for line in run.stdout.splitlines() if line.startswith('IOS_CPU_BUILD_SETTINGS=')]
                self.assertEqual(len(lines),1)
                self.assertEqual(json.loads(lines[0].split('=',1)[1]),{'GCC_OPTIMIZATION_LEVEL':'s',
                    'OTHER_CFLAGS':'','SWIFT_OPTIMIZATION_LEVEL':'-O','ENABLE_TESTABILITY':'YES'})
                self.assertNotIn('must-not-publish',run.stdout+run.stderr)
                self.assertIn('IOS_CPU_YADIF_BENCH width=1920',log)
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
    def test_functional_results_are_reported_before_independent_cpu_measurement(self):
        text=(ROOT/'.github/workflows/ios-ci.yml').read_text()
        self.assertIn('name: Report startup and functional test results',text)
        first=text.split('name: Report startup and functional test results',1)[1].split('      - name:',1)[0]
        self.assertIn('if: always()',first)
        self.assertIn('for bundle in iOS-RunnerControl iOS-Release iOS;',first)
        self.assertNotIn('iOS-CPU-Release',first)
        self.assertIn('report-ios-test-status.py "$RUNNER_TEMP/iOS.xcresult" || status=1',first)
        self.assertIn('exit "$status"',first)
        self.assertLess(text.index('Run shared playback and iPhone touch tests'),text.index('Report startup and functional test results'))
        self.assertLess(text.index('Report startup and functional test results'),text.index('Measure optimized CPU processing'))
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
        self.assertEqual(text.count(relay),1)
        self.assertIn(relay,script)
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory);(directory/'Scripts').mkdir();(directory/'bin').mkdir()
            native=directory/'Scripts/test-ios.sh'
            native.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS_LOG"\nprintf "native output\\n"\nexit "$NATIVE_EXIT"\n')
            native.chmod(0o755)
            observer=directory/'bin/python3'
            observer.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$RELAY_ARGS_LOG"\ncat\nexit 0\n')
            observer.chmod(0o755)
            args_log=directory/'args';relay_args_log=directory/'relay-args'
            expected=['-configuration','Debug','-derivedDataPath',str(directory/'iOS-Simulator'),
                '-resultBundlePath',str(directory/'iOS.xcresult'),'-parallel-testing-enabled','NO',
                '-collect-test-diagnostics','never','-test-timeouts-enabled','YES',
                '-default-test-execution-time-allowance','120','-maximum-test-execution-time-allowance','300']
            for code in [0,7]:
                run=subprocess.run(['bash','-e','-c',script],cwd=directory,env=dict(os.environ,
                    PATH=str(directory/'bin')+os.pathsep+os.environ['PATH'],RUNNER_TEMP=str(directory),
                    CANDIDATE_SHA='a'*40,ARGS_LOG=str(args_log),RELAY_ARGS_LOG=str(relay_args_log),
                    NATIVE_EXIT=str(code)),capture_output=True,text=True,timeout=3)
                self.assertEqual(run.returncode,code,run.stderr)
                self.assertEqual(run.stdout,'native output\n')
                self.assertEqual(args_log.read_text().splitlines(),expected)
                self.assertEqual(relay_args_log.read_text().splitlines(),['Scripts/report-ios-pip-runtime.py','--candidate','a'*40])
if __name__=='__main__':unittest.main()
