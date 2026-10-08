#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import importlib.util
import contextlib
import io
import os
import signal
import subprocess
import time
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
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
    def test_linux_global_inventory_distinguishes_zombies_live_and_other_groups(self):
        module=self.module()
        for output,expected in [('10 100 Z\n11 100 Z+\n12 101 S\n',False),('10 100 S\n',True),('10 100 Z\n11 100 T\n',True),('12 101 S\n',False)]:
            with patch.object(module.sys,'platform','linux'), patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout=output,stderr="",returncode=0)):
                self.assertEqual(module.group_has_executing_members(100),expected)
        with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='ambiguous',stderr='',returncode=0)):
            with self.assertRaises(RuntimeError):module.group_has_executing_members(100)
    def test_unreadable_inventory_and_live_survivor_fail_cleanup(self):
        module=self.module()
        with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='',stderr='',returncode=0)):
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
                self.assertFalse(module.signal_group_or_retired(100,0));check.assert_called_once_with(100,timeout=3,require_leader=False)
            with patch.object(module,'group_has_executing_members',return_value=True):
                with self.assertRaises(PermissionError):module.signal_group_or_retired(100,0)
            with patch.object(module,'group_has_executing_members',side_effect=RuntimeError('unreadable')):
                with self.assertRaises(RuntimeError):module.signal_group_or_retired(100,0)
    def test_darwin_inventory_is_scoped_and_overrides_legacy_mode(self):
        module=self.module()
        reply=SimpleNamespace(stdout='101 100 Z<\n',stderr='',returncode=0)
        with patch.object(module.sys,'platform','darwin'), patch.dict(module.os.environ,{'COMMAND_MODE':'legacy'}), patch.object(module.subprocess,'run',return_value=reply) as run:
            self.assertFalse(module.group_has_executing_members(100))
            self.assertEqual(run.call_args.args[0],['/bin/ps','-g','100','-o','pid=,pgid=,stat='])
            self.assertEqual(run.call_args.kwargs['env']['COMMAND_MODE'],'unix2003')
            self.assertEqual(run.call_args.kwargs['env']['LC_ALL'],'C')

    def test_darwin_no_match_requires_exact_exit_and_empty_stderr(self):
        module=self.module()
        with patch.object(module.sys,'platform','darwin'):
            with patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='',stderr='',returncode=1)):
                self.assertFalse(module.group_has_executing_members(100))
            for code,out,err in [(0,'',''),(1,'','permission denied'),(2,'',''),(0,'101 100 Z\n','sysctl failed'),(0,'101 999 Z\n',''),(0,'101 100 Zgarbage\n',''),(1,'101 100 Z\n','')]:
                with self.subTest(code=code,out=out,err=err), patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout=out,stderr=err,returncode=code)):
                    with self.assertRaises(RuntimeError):module.group_has_executing_members(100)

    def test_terminal_group_proof_precedes_reap_and_is_not_requeried(self):
        module=self.module();events=[]
        def reap(timeout):events.append('reap');self.assertEqual(events,['signal','proof','reap']);return 0
        process=SimpleNamespace(pid=100,poll=lambda: self.fail('leader must remain unreaped'),wait=reap)
        def signal_group(pgid,sig,**kwargs):events.append('signal');return True
        def inventory(pgid,**kwargs):events.append('proof');return False
        with patch.object(module.sys,'platform','linux'), patch.object(module,'signal_group_or_retired',side_effect=signal_group) as send, patch.object(module,'group_has_executing_members',side_effect=inventory) as query:
            module.retire_owned_group(process,graces=[(signal.SIGINT,0.1)])
            self.assertEqual(send.call_count,1);self.assertEqual(query.call_count,1)

    def test_esrch_terminal_proof_never_queries_or_signals_again(self):
        module=self.module();events=[]
        process=SimpleNamespace(pid=100,poll=lambda:self.fail('unexpected reap'),wait=lambda timeout:events.append('reap'))
        with patch.object(module,'signal_group_or_retired',return_value=False) as send, patch.object(module,'group_has_executing_members',side_effect=AssertionError('query after terminal proof')):
            module.retire_owned_group(process,graces=[(signal.SIGINT,0),(signal.SIGKILL,0)])
            self.assertEqual(send.call_count,1);self.assertEqual(events,['reap'])

    def test_inventory_uncertainty_keeps_owned_escalation_but_never_claims_retired(self):
        module=self.module();signals=[];clock=[0.0]
        process=SimpleNamespace(pid=100,poll=lambda:self.fail('premature reap'),wait=lambda timeout:self.fail('no retirement proof'))
        with patch.object(module.sys,'platform','linux'), patch.object(module.time,'monotonic',side_effect=lambda:clock[0]), patch.object(module.time,'sleep',side_effect=lambda duration:clock.__setitem__(0,clock[0]+duration)), patch.object(module,'signal_group_or_retired',side_effect=lambda pgid,sig,**kwargs:signals.append(sig) or True), patch.object(module,'group_has_executing_members',side_effect=subprocess.TimeoutExpired(['ps'],3)):
            with self.assertRaisesRegex(RuntimeError,'unverified'):
                module.retire_owned_group(process,graces=[(signal.SIGINT,0.1),(signal.SIGTERM,0.1),(signal.SIGKILL,0.1)])
        self.assertEqual(signals,[signal.SIGINT,signal.SIGTERM,signal.SIGKILL])

    def test_cleanup_error_preserves_original_timeout_and_end_marker(self):
        module=self.module();out=io.StringIO()
        original=module.retire_owned_group
        def retire_then_report_unverified(process):
            original(process)
            raise subprocess.TimeoutExpired(['ps'],3)
        with tempfile.TemporaryDirectory() as directory, patch.object(module,'retire_owned_group',side_effect=retire_then_report_unverified), contextlib.redirect_stdout(out):
            code,_=module.run_command('bootstatus',[sys.executable,'-c','import time; time.sleep(30)'],0.05,Path(directory),lambda:None)
        self.assertEqual(code,124)
        self.assertIn('IOS_STARTUP_PHASE_TIMEOUT=bootstatus',out.getvalue())
        self.assertIn('IOS_STARTUP_CLEANUP_UNVERIFIED=TimeoutExpired',out.getvalue())
        self.assertIn('IOS_STARTUP_PHASE_END=bootstatus exit=124 timed_out=True',out.getvalue())
        self.assertNotIn('subprocess.TimeoutExpired:',out.getvalue())

    def test_bootstatus_samples_exact_owned_pid_before_any_inventory(self):
        module=self.module();commands=[]
        def invoke(command,**kwargs):commands.append(command);return SimpleNamespace(stdout='',returncode=1)
        with tempfile.TemporaryDirectory() as directory, patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',side_effect=invoke):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcrun','simctl','bootstatus','12345678-1234-1234-1234-123456789012','-b'])
        self.assertTrue(commands)
        self.assertEqual(commands[0][0:3],['sample','123','2'])
        self.assertFalse(any('-axo' in command for command in commands))

    def test_scoped_inventory_permission_error_is_visible_without_fallback(self):
        module=self.module();out=io.StringIO()
        with patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='',stderr='Operation not permitted',returncode=1)) as run, contextlib.redirect_stdout(out):
            with self.assertRaises(RuntimeError):module.group_has_executing_members(100)
        self.assertEqual(run.call_count,1)
        self.assertIn('Operation not permitted',out.getvalue())
        self.assertIn('"pgid": 100',out.getvalue())

    def test_already_reaped_leader_never_receives_group_signal(self):
        module=self.module()
        process=SimpleNamespace(pid=100,returncode=0,wait=lambda timeout:0)
        with patch.object(module.os,'killpg') as send:
            with self.assertRaisesRegex(RuntimeError,'already reaped'):
                module.retire_owned_group(process)
            send.assert_not_called()

    def test_permission_denial_with_live_members_stops_without_further_signals(self):
        module=self.module()
        process=SimpleNamespace(pid=100,returncode=None,poll=lambda:self.fail('premature reap'),wait=lambda timeout:self.fail('no proof'))
        with patch.object(module.os,'killpg',side_effect=PermissionError('denied')) as send, patch.object(module,'group_has_executing_members',return_value=True):
            with self.assertRaises(PermissionError):module.retire_owned_group(process)
            self.assertEqual(send.call_count,1)

    def test_expired_grace_never_grants_fresh_inventory_time(self):
        module=self.module()
        process=SimpleNamespace(pid=100,returncode=None,wait=Mock())
        with patch.object(module.time,'monotonic',side_effect=[0.0,1.0]), patch.object(module,'signal_group_or_retired',return_value=True), patch.object(module,'group_has_executing_members',return_value=False) as query:
            with self.assertRaisesRegex(RuntimeError,'unverified'):
                module.retire_owned_group(process,graces=[(signal.SIGKILL,1.0)])
            query.assert_not_called();process.wait.assert_not_called()

    def test_zero_grace_is_signal_only_and_never_queries_or_reaps(self):
        module=self.module()
        process=SimpleNamespace(pid=100,returncode=None,wait=Mock())
        with patch.object(module.time,'monotonic',return_value=0.0), patch.object(module,'signal_group_or_retired',return_value=True) as send, patch.object(module,'group_has_executing_members') as query:
            with self.assertRaisesRegex(RuntimeError,'unverified'):
                module.retire_owned_group(process,graces=[(signal.SIGINT,0),(signal.SIGKILL,0)])
            self.assertEqual(send.call_count,2);query.assert_not_called();process.wait.assert_not_called()

    def test_darwin_eperm_probe_uses_only_remaining_signal_grace(self):
        module=self.module()
        with patch.object(module.time,'monotonic',return_value=2.5), patch.object(module.os,'killpg',side_effect=PermissionError('zombie')), patch.object(module,'group_has_executing_members',return_value=False) as query:
            self.assertFalse(module.signal_group_or_retired(100,signal.SIGINT,deadline=3.0))
            query.assert_called_once_with(100,timeout=0.5,require_leader=False)
        with patch.object(module.time,'monotonic',return_value=3.0), patch.object(module.os,'killpg',side_effect=PermissionError('unknown')), patch.object(module,'group_has_executing_members') as query:
            with self.assertRaises(PermissionError):module.signal_group_or_retired(100,signal.SIGINT,deadline=3.0)
            query.assert_not_called()

    def test_retirement_inventory_requires_unique_pinned_leader(self):
        module=self.module()
        for rows in ['101 100 Z\n','100 100 Z\n100 100 Z\n']:
            with self.subTest(rows=rows), patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout=rows,stderr='',returncode=0)):
                with self.assertRaises(RuntimeError):module.group_has_executing_members(100,require_leader=True)
        with patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',return_value=SimpleNamespace(stdout='',stderr='',returncode=1)):
            with self.assertRaises(RuntimeError):module.group_has_executing_members(100,require_leader=True)

    def test_live_final_kernel_probe_prevents_zombie_snapshot_retirement(self):
        module=self.module()
        with patch.object(module.os,'killpg',side_effect=[PermissionError('raced'),None]) as send, patch.object(module,'group_has_executing_members',return_value=False):
            self.assertTrue(module.signal_group_or_retired(100,0))
            self.assertEqual(send.call_args_list[-1].args,(100,0))

    def test_darwin_live_kernel_probe_never_uses_ps_alone_to_retire(self):
        module=self.module();clock=[0.0]
        process=SimpleNamespace(pid=100,returncode=None,wait=Mock())
        with patch.object(module.sys,'platform','darwin'), patch.object(module.time,'monotonic',side_effect=lambda:clock[0]), patch.object(module.time,'sleep',side_effect=lambda value:clock.__setitem__(0,clock[0]+value)), patch.object(module.os,'killpg',return_value=None), patch.object(module,'group_has_executing_members',return_value=False) as query:
            with self.assertRaisesRegex(RuntimeError,'unverified'):
                module.retire_owned_group(process,graces=[(signal.SIGKILL,1)])
            query.assert_not_called();process.wait.assert_not_called()
            self.assertEqual(clock[0],1)

    def test_artifact_projection_excludes_environment_and_only_reports_allowed_keys(self):
        module=self.module()
        value={'EnvironmentVariables':{'TOKEN':'private'},'TestTargets':[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test'], 'Secret':'private'}]}
        projected=module.artifact_facts(value)
        self.assertEqual(projected,[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test']}])
        self.assertNotIn('private',str(projected))
if __name__=='__main__':unittest.main()
