#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import importlib.util
import os
import signal
import subprocess
import time
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
class IOSStartupRunnerTests(unittest.TestCase):
    def module(self):
        path=ROOT/'Scripts/Support/ios-startup-runner.py'
        self.assertTrue(path.exists(),'bounded iOS runner diagnostics are missing')
        spec=importlib.util.spec_from_file_location('ios_startup_runner',path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module
    def test_preserves_success_and_failure_exit_status(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            for status in [0,7]:
                code,_=module.run_command('control',[sys.executable,'-c',f'raise SystemExit({status})'],2,Path(directory),lambda:None)
                self.assertEqual(code,status)
    def test_timeout_is_failure_and_diagnostics_precede_owned_process_retirement(self):
        module=self.module();calls=[]
        with tempfile.TemporaryDirectory() as directory:
            code,_=module.run_command('timeout',[sys.executable,'-c','import time; time.sleep(30)'],0.05,Path(directory),lambda:calls.append('diagnostics'))
            self.assertEqual(code,124);self.assertEqual(calls,['diagnostics'])
    def test_retires_descendant_when_leader_exits_on_interrupt(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            pidfile=Path(directory)/'child.pid'
            child="import os,signal,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(%r,'w').write(str(os.getpid())); time.sleep(60)" % str(pidfile)
            parent="import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',%r]); time.sleep(60)" % child
            pid=None
            try:
                code,_=module.run_command('descendant',[sys.executable,'-c',parent],0.3,Path(directory),lambda:None)
                self.assertEqual(code,124)
                pid=int(pidfile.read_text())
                # Linux can briefly retain a killed orphan as a zombie; it is no longer executing.
                proc=Path('/proc')/str(pid)/'stat'
                if proc.exists():self.assertEqual(proc.read_text().split()[2],'Z')
                else:
                    state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True,check=False)
                    if state.returncode==0:self.assertTrue(state.stdout.strip().startswith('Z'))
                    else:self.assertEqual(state.returncode,1)
            finally:
                if pid is None and pidfile.exists():pid=int(pidfile.read_text())
                if pid:
                    try:os.kill(pid,signal.SIGKILL)
                    except ProcessLookupError:pass
    def test_startup_requires_all_three_successful_cold_starts(self):
        module=self.module()
        complete=b'IOS_RELEASE_STARTUP_TEST_ENTER\n'+b''.join(
            f'IOS_RELEASE_LIBRARY_READY index={i} ready=true\nIOS_RELEASE_TERMINATE_RETURNED index={i}\n'.encode() for i in range(3))
        self.assertTrue(module.startup_completed(complete))
        self.assertFalse(module.startup_completed(b''))
        self.assertFalse(module.startup_completed(complete.replace(b'index=2 ready=true',b'index=2 ready=false')))
        self.assertFalse(module.startup_completed(complete.replace(b'IOS_RELEASE_TERMINATE_RETURNED index=1',b'missing')))
    def test_timeout_preserves_pre_interrupt_progress(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            code,data=module.run_command('progress',[sys.executable,'-c',
                "import time; print('COMPILER_PROGRESS_BEFORE_INTERRUPT',flush=True); time.sleep(60)"],
                0.2,Path(directory),lambda:None)
            self.assertEqual(code,124)
            self.assertIn(b'COMPILER_PROGRESS_BEFORE_INTERRUPT',data)
            self.assertIn(b'PRE_INTERRUPT',data)
    def test_build_phase_is_generic_and_precedes_simulator_boot(self):
        source=(ROOT/'Scripts/Support/ios-startup-runner.py').read_text()
        self.assertIn("parser.add_argument('--build-only',action='store_true')",source)
        self.assertIn("'generic/platform=iOS Simulator'",source)
        self.assertLess(source.index('if args.build_only:'),source.index("if device['state']!='Booted':"))
    def test_compiler_sampling_matches_exact_derived_data_not_process_name(self):
        module=self.module()
        rows="10 1 10 0.1 01:00 10 /usr/bin/xcodebuild\n11 2 2 99 01:00 100 /x/swift-frontend -o /tmp/build/obj.o\n12 2 2 99 01:00 100 /x/swift-frontend -o /tmp/build-other/obj.o"
        result=module.owned_process_rows(rows,10,Path('/tmp/build'))
        self.assertEqual([row[0] for row in result],['10','11'])
        self.assertEqual(result[1][6],'/x/swift-frontend')
    def test_capture_failure_still_retires_owned_process(self):
        module=self.module()
        def broken_capture(_):raise OSError('synthetic unreadable log')
        module.bounded_log=broken_capture
        with tempfile.TemporaryDirectory() as directory:
            pidfile=Path(directory)/'owned.pid'
            command="import os,time; open(%r,'w').write(str(os.getpid())); time.sleep(60)" % str(pidfile)
            code,_=module.run_command('capture-failure',[sys.executable,'-c',command],
                0.2,Path(directory),lambda:None)
            self.assertEqual(code,124)
            with self.assertRaises(ProcessLookupError):os.kill(int(pidfile.read_text()),0)
    def test_darwin_zombie_only_group_is_not_executing_but_live_member_is(self):
        module=self.module()
        for output,expected in [('10 100 Z\n11 100 Z+\n12 101 S\n',False),('10 100 S\n',True),('10 100 Z\n11 100 T\n',True),('12 101 S\n',False)]:
            with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout=output)):
                self.assertEqual(module.group_has_executing_members(100),expected)
        with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='ambiguous')):
            with self.assertRaises(RuntimeError):module.group_has_executing_members(100)
    def test_unreadable_inventory_and_live_survivor_fail_cleanup(self):
        module=self.module()
        with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='')):
            with self.assertRaises(RuntimeError):module.group_has_executing_members(100)
        with patch.object(module.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['ps'])):
            with self.assertRaises(subprocess.CalledProcessError):module.group_has_executing_members(100)
        process=SimpleNamespace(pid=100,poll=lambda:0,wait=lambda timeout:0)
        with patch.object(module,'signal_group_or_retired',return_value=True), patch.object(module,'group_has_executing_members',return_value=True):
            with self.assertRaisesRegex(RuntimeError,'executing descendants'):
                module.retire_owned_group(process,graces=[(signal.SIGKILL,0)])
    def test_zero_signal_permission_error_requires_verified_group_retirement(self):
        module=self.module()
        with patch.object(module.os,'killpg',side_effect=PermissionError('synthetic Darwin group')):
            with patch.object(module,'group_has_executing_members',return_value=False) as check:
                self.assertFalse(module.signal_group_or_retired(100,0));check.assert_called_once_with(100)
            with patch.object(module,'group_has_executing_members',return_value=True):
                with self.assertRaises(PermissionError):module.signal_group_or_retired(100,0)
            with patch.object(module,'group_has_executing_members',side_effect=RuntimeError('unreadable')):
                with self.assertRaises(RuntimeError):module.signal_group_or_retired(100,0)
    def test_artifact_projection_excludes_environment_and_only_reports_allowed_keys(self):
        module=self.module()
        value={'EnvironmentVariables':{'TOKEN':'private'},'TestTargets':[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test'], 'Secret':'private'}]}
        projected=module.artifact_facts(value)
        self.assertEqual(projected,[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test']}])
        self.assertNotIn('private',str(projected))
if __name__=='__main__':unittest.main()
