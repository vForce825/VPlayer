#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import importlib.util
import contextlib
import io
import json
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
                code,_=module.run_command('control',[sys.executable,'-c',f'raise SystemExit({status})'],2,Path(directory),lambda deadline:None)
                self.assertEqual(code,status)
    def test_timeout_is_failure_and_diagnostics_precede_owned_process_retirement(self):
        module=self.module();calls=[]
        with tempfile.TemporaryDirectory() as directory:
            code,_=module.run_command('timeout',[sys.executable,'-c','import time; time.sleep(30)'],0.05,Path(directory),lambda deadline:calls.append('diagnostics'))
            self.assertEqual(code,124);self.assertEqual(calls,['diagnostics'])
    def test_retires_descendant_when_leader_exits_on_interrupt(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            pidfile=Path(directory)/'child.pid'
            child="import os,signal,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(%r,'w').write(str(os.getpid())); time.sleep(60)" % str(pidfile)
            parent="import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',%r]); time.sleep(60)" % child
            pid=None
            try:
                code,_=module.run_command('descendant',[sys.executable,'-c',parent],0.3,Path(directory),lambda deadline:None)
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
                0.2,Path(directory),lambda deadline:None)
            self.assertEqual(code,124)
            self.assertIn(b'COMPILER_PROGRESS_BEFORE_INTERRUPT',data)
            self.assertIn(b'PRE_INTERRUPT',data)
    def test_build_phase_is_generic_and_precedes_simulator_boot(self):
        source=(ROOT/'Scripts/Support/ios-startup-runner.py').read_text()
        self.assertIn("modes.add_argument('--build-only',action='store_true')",source)
        self.assertIn("'generic/platform=iOS Simulator'",source)
        self.assertLess(source.index('if args.build_only or args.build_shipping:'),source.index("if device['state']!='Booted':"))
    def test_shipping_simulator_build_uses_existing_bounded_owned_process_supervision(self):
        module=self.module()
        device='00000000-0000-0000-0000-000000000001'
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[
            {'udid':device,'isAvailable':True,'name':'iPhone 17','state':'Shutdown'}]}}
        calls=[]
        def build(label,command,timeout,directory,diagnostics,capture_log=None):
            self.assertIsNotNone(capture_log)
            calls.append((label,command,timeout))
            return 7,b'build failed'
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'argv',[
                'runner','--build-shipping','--simulator',device,'--derived-data',directory,
                '--build-log',directory+'/verified.log']),patch.object(module.subprocess,'check_output',
                return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=build),contextlib.redirect_stdout(io.StringIO()):
            try: code=module.main()
            except SystemExit as error: code=error.code
            self.assertEqual(code,7)
        self.assertEqual(len(calls),1)
        label,command,timeout=calls[0]
        self.assertEqual(label,'build')
        self.assertEqual(command[:2],['xcodebuild','build'])
        self.assertEqual(command[command.index('-scheme')+1],'VPlayeriOSRelease')
        self.assertEqual(command[command.index('-destination')+1],'generic/platform=iOS Simulator')
        self.assertEqual(timeout,480)
        self.assertFalse(any('COVERAGE' in argument or argument=='-enableCodeCoverage' for argument in command))

    def test_build_capture_preserves_full_stream_without_unbounded_supervisor_copy(self):
        module=self.module()
        complete=b'CompileC original first command\n'+b'x'*65536+b'\nlast command\n'
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory); log=directory/'verified.log'
            command=[sys.executable,'-c',"import os; os.write(1,"+repr(complete)+")"]
            with contextlib.redirect_stdout(io.StringIO()):
                code,_=module.run_command('build',command,5,directory,lambda deadline:None,capture_log=log)
            self.assertEqual(code,0)
            self.assertEqual(log.read_bytes(),complete)
            self.assertTrue(Path(str(log)+'.capture.json').exists())
            self.assertNotIn(b'original first command',(directory/'build.supervisor.log').read_bytes())

    def test_build_capture_preserves_native_failure_and_timeout_cleanup(self):
        module=self.module()
        for exit_code in [0,7]:
            with self.subTest(exit_code=exit_code),tempfile.TemporaryDirectory() as directory:
                directory=Path(directory); log=directory/'verified.log'
                with contextlib.redirect_stdout(io.StringIO()):
                    code,_=module.run_command('build',[sys.executable,'-c',
                        f"print('native compiler output'); raise SystemExit({exit_code})"],
                        5,directory,lambda deadline:None,capture_log=log)
                self.assertEqual(code,exit_code)
                self.assertIn(b'native compiler output',log.read_bytes())
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory); log=directory/'verified.log'; pidfile=directory/'native.pid'
            command=[sys.executable,'-c',
                f"import os,time; open({str(pidfile)!r},'w').write(str(os.getpid())); print('in-flight compiler',flush=True); time.sleep(60)"]
            with contextlib.redirect_stdout(io.StringIO()):
                code,data=module.run_command('build',command,1,directory,lambda deadline:None,capture_log=log)
            self.assertEqual(code,124)
            self.assertIn(b'in-flight compiler',data)
            pid=int(pidfile.read_text())
            proc=Path('/proc')/str(pid)/'stat'
            if proc.exists():self.assertEqual(proc.read_text().split()[2],'Z')
            else:
                with self.assertRaises(ProcessLookupError):os.kill(pid,0)

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
                0.2,Path(directory),lambda deadline:None)
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
            code,_=module.run_command('bootstatus',[sys.executable,'-c','import time; time.sleep(30)'],0.05,Path(directory),lambda deadline:None)
        self.assertEqual(code,124)
        self.assertIn('IOS_STARTUP_PHASE_TIMEOUT=bootstatus',out.getvalue())
        self.assertIn('IOS_STARTUP_CLEANUP_UNVERIFIED=TimeoutExpired',out.getvalue())
        self.assertIn('IOS_STARTUP_PHASE_END=bootstatus exit=124 timed_out=True',out.getvalue())
        self.assertNotIn('subprocess.TimeoutExpired:',out.getvalue())

    def test_wrapped_build_samples_direct_native_child_before_swift_with_existing_deadline(self):
        module=self.module();commands=[]
        rows=('123 1 123 0.1 00:01 100 /usr/bin/python3\n'
              '124 123 123 0.1 00:01 100 /Xcode/usr/bin/xcodebuild\n'
              '125 999 123 0.1 00:01 100 /Other/xcodebuild\n'
              '126 123 999 0.1 00:01 100 /Unowned/xcodebuild\n'
              '127 124 123 50.0 00:01 100 /Xcode/swift-frontend -o /tmp/build/a.o\n')
        def invoke(command,**kwargs):
            commands.append((command,kwargs.get('timeout')))
            return SimpleNamespace(stdout=rows if command[0]=='/bin/ps' else '',stderr='',returncode=0)
        process=SimpleNamespace(pid=123,args=[sys.executable,str(
            ROOT/'Scripts/Support/capture-release-build.py'),'--log','/tmp/build.log'])
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'platform','darwin'),patch.object(
                module,'observe_owned_identity',return_value=True),patch.object(module.subprocess,'run',side_effect=invoke),contextlib.redirect_stdout(io.StringIO()):
            module.sample_owned_processes(process,Path(directory),
                ['xcodebuild','build','-derivedDataPath','/tmp/build'],deadline=time.monotonic()+25)
        self.assertEqual(commands[0][0][:3],['/bin/ps','-g','123'])
        samples=[command for command,_ in commands if command[0]=='sample']
        self.assertEqual([command[1] for command in samples],['124','127'])
        self.assertTrue(all(timeout<=8 for command,timeout in commands if command[0]=='sample'))

    def test_bootstatus_observes_exact_owned_pid_before_sample_without_inventory(self):
        module=self.module();commands=[]
        def invoke(command,**kwargs):commands.append(command);return SimpleNamespace(stdout='',returncode=1)
        with tempfile.TemporaryDirectory() as directory, patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',side_effect=invoke):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcrun','simctl','bootstatus','12345678-1234-1234-1234-123456789012','-b'])
        self.assertTrue(commands)
        self.assertEqual(commands[0][0],sys.executable)
        self.assertEqual(commands[0][-1],'123')
        self.assertEqual(commands[1][0:3],['sample','123','2'])
        self.assertFalse(any('-axo' in command for command in commands))

    def test_sample_timeout_keeps_bounded_partial_diagnostic_and_stack(self):
        module=self.module();out=io.StringIO()
        def invoke(command,**kwargs):
            if command[0]!='sample':return SimpleNamespace(returncode=0)
            kwargs['stdout'].write(b'ATTACH_DIAGNOSTIC\n'+b'x'*70000+b'\nDIAGNOSTIC_TAIL\n')
            kwargs['stdout'].flush()
            Path(command[-1]).write_bytes(b'PARTIAL_STACK\n'+b'x'*70000+b'\nSTACK_TAIL\n')
            raise subprocess.TimeoutExpired(command,kwargs['timeout'])
        with tempfile.TemporaryDirectory() as directory, patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',side_effect=invoke), contextlib.redirect_stdout(out):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcrun','simctl','bootstatus','device','-b'])
        for marker in ['ATTACH_DIAGNOSTIC','DIAGNOSTIC_TAIL','PARTIAL_STACK','STACK_TAIL','IOS_STARTUP_PROCESS_SAMPLE_TIMEOUT=123']:
            self.assertIn(marker,out.getvalue())
        self.assertLess(len(out.getvalue()),52000)

    def test_identity_timeout_keeps_partial_output_and_continues_to_sample(self):
        module=self.module();out=io.StringIO();commands=[]
        def invoke(command,**kwargs):
            commands.append((command,kwargs['timeout']))
            if command[0]==sys.executable:
                kwargs['stdout'].write(b'IDENTITY_BEFORE_PATH_STALL\n');kwargs['stdout'].flush()
                raise subprocess.TimeoutExpired(command,kwargs['timeout'])
            return SimpleNamespace(returncode=0)
        with tempfile.TemporaryDirectory() as directory, patch.object(module.sys,'platform','darwin'), patch.object(module.subprocess,'run',side_effect=invoke), contextlib.redirect_stdout(out):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcrun','simctl','bootstatus','device','-b'])
        self.assertIn('IDENTITY_BEFORE_PATH_STALL',out.getvalue())
        self.assertIn('IOS_STARTUP_PROCESS_IDENTITY_TIMEOUT=123',out.getvalue())
        self.assertEqual(commands[0][1],2)
        self.assertEqual(commands[1][0][0],'sample')

    def test_identity_permission_denial_stops_before_second_api(self):
        module=self.module();self.assertTrue(hasattr(module,'native_process_identity'))
        import ctypes,errno
        def denied(pid,buffer,size):
            self.assertEqual((pid,size),(123,4096));ctypes.set_errno(errno.EPERM);return 0
        library=SimpleNamespace(proc_name=Mock(side_effect=denied),proc_pidpath=Mock())
        out=io.StringIO()
        with patch.object(module.sys,'platform','darwin'),patch.object(ctypes,'CDLL',return_value=library),contextlib.redirect_stdout(out):
            self.assertEqual(module.native_process_identity(123),77)
        library.proc_pidpath.assert_not_called()
        facts=json.loads(out.getvalue().splitlines()[-1].split('=',1)[1])
        self.assertEqual((facts['pid'],facts['api'],facts['result'],facts['errno']),(123,'proc_name',0,errno.EPERM))

    def test_identity_reports_each_api_without_hiding_exec_transition(self):
        module=self.module();self.assertTrue(hasattr(module,'native_process_identity'))
        import ctypes
        def value(text):
            def read(pid,buffer,size):buffer.value=text;return len(text)
            return read
        library=SimpleNamespace(proc_name=Mock(side_effect=value(b'xcrun')),proc_pidpath=Mock(side_effect=value(b'/Xcode/simctl')))
        out=io.StringIO()
        with patch.object(module.sys,'platform','darwin'),patch.object(ctypes,'CDLL',return_value=library),contextlib.redirect_stdout(out):
            ctypes.set_errno(13)
            self.assertEqual(module.native_process_identity(123),0)
        rows=[json.loads(line.split('=',1)[1]) for line in out.getvalue().splitlines() if line.startswith('IOS_STARTUP_PROCESS_IDENTITY=')]
        self.assertEqual([row['value'] for row in rows],['xcrun','/Xcode/simctl'])
        self.assertEqual([row['errno'] for row in rows],[0,0])
        self.assertEqual([row['api'] for row in rows],['proc_name','proc_pidpath'])

    def test_only_bootstatus_gets_command_local_unbuffered_request(self):
        module=self.module();commands=[['xcrun','simctl','bootstatus','device','-b'],['xcrun','simctl','boot','device'],['xcodebuild','build']]
        original={'STDBUF1':'L','_STDBUF_O':'L','UNRELATED':'preserved'}
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'platform','darwin'),patch.dict(module.os.environ,original,clear=True):
            for index,command in enumerate(commands):
                with patch.object(module.subprocess,'Popen',return_value=SimpleNamespace(wait=lambda timeout:0)) as spawn:
                    module.run_command('environment-'+str(index),command,1,Path(directory),lambda deadline:None)
                child=spawn.call_args.kwargs.get('env')
                if index==0:
                    self.assertIsNotNone(child)
                    self.assertEqual((child['STDBUF1'],child['_STDBUF_O']),('0','0'))
                    self.assertEqual(child['UNRELATED'],'preserved')
                else:self.assertIsNone(child)
                self.assertTrue(spawn.call_args.kwargs['start_new_session'])
                self.assertEqual(dict(module.os.environ),original)

    def test_host_load_output_is_fixed_numeric_facts(self):
        module=self.module();self.assertTrue(hasattr(module,'host_load_facts'));out=io.StringIO()
        with patch.object(module.os,'getloadavg',return_value=(1.0,2.0,3.0)),patch.object(module.os,'cpu_count',return_value=3),contextlib.redirect_stdout(out):
            module.host_load_facts('pre-boot')
        facts=json.loads(out.getvalue().split('=',1)[1])
        self.assertEqual(facts,{'context':'pre-boot','cpu_count':3,'loadavg_1m':1.0,'loadavg_5m':2.0,'loadavg_15m':3.0})

    def test_shared_diagnostic_deadline_prevents_later_sample_and_inventory(self):
        module=self.module();self.assertTrue(hasattr(module,'diagnostic_remaining'));clock=[0.0];calls=[]
        def invoke(command,**kwargs):
            calls.append((command,kwargs['timeout']));clock[0]+=kwargs['timeout']
            raise subprocess.TimeoutExpired(command,kwargs['timeout'])
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'platform','darwin'),patch.object(module.time,'monotonic',side_effect=lambda:clock[0]),patch.object(module.subprocess,'run',side_effect=invoke):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcodebuild','build'],deadline=2)
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][1],2)
        self.assertEqual(clock[0],2)

    def test_identity_permission_exit_does_not_try_another_observation_path(self):
        module=self.module();calls=[]
        def invoke(command,**kwargs):calls.append(command);return SimpleNamespace(returncode=77)
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'platform','darwin'),patch.object(module.subprocess,'run',side_effect=invoke):
            module.sample_owned_processes(SimpleNamespace(pid=123),Path(directory),['xcrun','simctl','bootstatus','device','-b'])
        self.assertEqual(len(calls),1)

    def test_timeout_observers_share_one_deadline_before_cleanup(self):
        module=self.module();seen=[]
        def sample(process,directory,command,deadline):seen.append(('sample',deadline))
        with tempfile.TemporaryDirectory() as directory,patch.object(module,'sample_owned_processes',side_effect=sample):
            code,_=module.run_command('budget',[sys.executable,'-c','import time; time.sleep(30)'],0.05,Path(directory),lambda deadline:seen.append(('simulator',deadline)))
        self.assertEqual(code,124)
        self.assertEqual([kind for kind,_ in seen],['sample','simulator'])
        self.assertEqual(seen[0][1],seen[1][1])

    def test_missing_host_load_is_reported_without_raising(self):
        module=self.module();out=io.StringIO()
        with patch.object(module.os,'getloadavg',side_effect=OSError(5,'unavailable')),contextlib.redirect_stdout(out):
            module.host_load_facts('pre-boot')
        self.assertIn('IOS_STARTUP_HOST_LOAD_UNAVAILABLE=',out.getvalue())
        self.assertIn('"errno": 5',out.getvalue())

    def test_preboot_load_is_observed_before_the_single_boot_attempt(self):
        module=self.module();events=[];device='12345678-1234-1234-1234-123456789012'
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone test','state':'Shutdown'}]}}
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'argv',['runner','--simulator',device,'--derived-data',directory]),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'host_load_facts',side_effect=lambda context:events.append(context)),patch.object(module,'run_command',side_effect=lambda label,*args:events.append(label) or (7,b'')):
            self.assertEqual(module.main(),7)
        self.assertEqual(events,['resolve-simctl','pre-boot','boot'])

    def test_boot_only_selects_shutdown_iphone_and_never_builds_or_tests(self):
        module=self.module();device='12345678-1234-1234-1234-123456789012';calls=[];out=io.StringIO()
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[
            {'udid':'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA','isAvailable':True,'name':'iPhone busy','state':'Booted'},
            {'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        def run(label,command,timeout,*args):calls.append((label,command,timeout));return 0,b''
        with patch.object(module.sys,'argv',['runner','--boot-only']),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=run),contextlib.redirect_stdout(out):
            try:code=module.main()
            except SystemExit as error:self.fail('boot-only mode is missing: '+str(error))
        self.assertEqual(code,0)
        self.assertEqual(calls,[('first-launch-status',['xcodebuild','-checkFirstLaunchStatus'],10),
            ('resolve-simctl',['/usr/bin/xcrun','--find','simctl'],5),
            ('boot',['xcrun','simctl','boot',device],30),('bootstatus',['xcrun','simctl','bootstatus',device,'-b'],120)])
        self.assertIn('IOS_BOOT_PROBE_APP_AND_XCTEST=not_run',out.getvalue())
        self.assertIn('"outcome": "boot_ready"',out.getvalue())
        self.assertIn(device,out.getvalue())

    def test_boot_only_rejects_already_booted_selection_without_boot_retry(self):
        module=self.module();device='12345678-1234-1234-1234-123456789012';out=io.StringIO()
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone busy','state':'Booted'}]}}
        with patch.object(module.sys,'argv',['runner','--boot-only','--simulator',device]),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command') as run,contextlib.redirect_stdout(out):
            try:code=module.main()
            except SystemExit as error:self.fail('boot-only classification is missing: '+str(error))
        self.assertEqual(code,1);run.assert_not_called()
        self.assertIn('unverified_non_shutdown',out.getvalue())

    def test_boot_only_failure_preserves_exit_and_does_not_start_tests(self):
        module=self.module();device='12345678-1234-1234-1234-123456789012';out=io.StringIO()
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        for phase in ['boot','bootstatus']:
            calls=[]
            def run(label,*args):
                calls.append(label)
                return (69 if label=='first-launch-status' else 124 if label==phase else 0),b''
            with self.subTest(phase=phase),patch.object(module.sys,'argv',['runner','--boot-only']),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=run),contextlib.redirect_stdout(out):
                try:code=module.main()
                except SystemExit as error:self.fail('boot-only failure classification is missing: '+str(error))
                self.assertEqual(code,124)
                self.assertEqual(calls,['first-launch-status','resolve-simctl','boot'] if phase=='boot' else ['first-launch-status','resolve-simctl','boot','bootstatus'])
        self.assertIn('"outcome": "failed"',out.getvalue())
        self.assertIn('IOS_BOOT_PROBE_FIRST_LAUNCH_STATUS={"exit": 69}',out.getvalue())

    def test_verified_simctl_path_is_used_only_for_existing_timeout_inventory(self):
        module=self.module();device='12345678-1234-1234-1234-123456789012';commands=[]
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        def run(label,command,timeout,directory,diagnostics):
            if label=='resolve-simctl':return 0,b'/verified/Xcode/usr/bin/simctl\n'
            self.assertEqual(command,['xcrun','simctl','boot',device])
            diagnostics(module.time.monotonic()+25)
            return 124,b''
        def diagnostic(command,**kwargs):commands.append(command);return SimpleNamespace(returncode=1)
        with tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'argv',['runner','--simulator',device,'--derived-data',directory]),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=run),patch.object(module.subprocess,'run',side_effect=diagnostic):
            self.assertEqual(module.main(),124)
        self.assertEqual(commands,[['/verified/Xcode/usr/bin/simctl','list','devices','booted','-j']])

    def test_invalid_or_failed_simctl_resolution_does_not_invent_a_direct_path(self):
        module=self.module();device='12345678-1234-1234-1234-123456789012'
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        for exit_code,data in [(0,b'relative/simctl\n'),(0,b'/bin/other\n'),(0,b'/a/simctl\n/b/simctl\n'),(69,b'/valid/simctl\n'),(0,b'\xff')]:
            commands=[];out=io.StringIO()
            def run(label,command,timeout,directory,diagnostics):
                if label=='resolve-simctl':return exit_code,data
                self.assertEqual(command,['xcrun','simctl','boot',device])
                diagnostics(module.time.monotonic()+25);return 124,b''
            def diagnostic(command,**kwargs):commands.append(command);return SimpleNamespace(returncode=1)
            with self.subTest(data=data),tempfile.TemporaryDirectory() as directory,patch.object(module.sys,'argv',['runner','--simulator',device,'--derived-data',directory]),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=run),patch.object(module.subprocess,'run',side_effect=diagnostic),contextlib.redirect_stdout(out):
                self.assertEqual(module.main(),124)
                self.assertEqual(commands,[['xcrun','simctl','list','devices','booted','-j']])
                self.assertIn('"result": "unverified"',out.getvalue())

    def test_acceptance_modes_still_require_explicit_destination_and_derived_data(self):
        module=self.module()
        for mode in [[],['--build-only']]:
            with self.subTest(mode=mode),patch.object(module.sys,'argv',['runner']+mode),patch.object(module.subprocess,'check_output') as inventory,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:module.main()
                self.assertEqual(raised.exception.code,2);inventory.assert_not_called()

    def test_first_launch_status_timeout_keeps_probe_unverified_without_boot(self):
        module=self.module();out=io.StringIO();device='12345678-1234-1234-1234-123456789012'
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        with patch.object(module.sys,'argv',['runner','--boot-only']),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',return_value=(124,b'')) as run,contextlib.redirect_stdout(out):
            self.assertEqual(module.main(),124)
        self.assertEqual(run.call_count,1)
        self.assertIn('unverified_preflight_timeout',out.getvalue())

    def test_boot_probe_does_not_shorten_bootstatus_to_fit_an_exhausted_budget(self):
        module=self.module();out=io.StringIO();device='12345678-1234-1234-1234-123456789012';clock=[0.0];calls=[]
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0':[{'udid':device,'isAvailable':True,'name':'iPhone cold','state':'Shutdown'}]}}
        def run(label,*args):calls.append(label);clock[0]+=40;return 0,b''
        with patch.object(module.sys,'argv',['runner','--boot-only']),patch.object(module.time,'monotonic',side_effect=lambda:clock[0]),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command',side_effect=run),contextlib.redirect_stdout(out):
            self.assertEqual(module.main(),124)
        self.assertEqual(calls,['first-launch-status','resolve-simctl','boot'])
        self.assertIn('unverified_budget_exhausted',out.getvalue())

    def test_boot_only_never_falls_back_to_another_runtime(self):
        module=self.module();out=io.StringIO()
        inventory={'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-27-0-extra':[{'udid':'12345678-1234-1234-1234-123456789012','isAvailable':True,'name':'iPhone wrong','state':'Shutdown'}]}}
        with patch.object(module.sys,'argv',['runner','--boot-only']),patch.object(module.subprocess,'check_output',return_value=json.dumps(inventory)),patch.object(module,'run_command') as run,contextlib.redirect_stdout(out):
            try:code=module.main()
            except SystemExit as error:self.fail('boot-only no-device classification is missing: '+str(error))
        self.assertEqual(code,1);run.assert_not_called()
        self.assertIn('unverified_no_shutdown_device',out.getvalue())

    def test_build_and_boot_only_modes_are_mutually_exclusive(self):
        module=self.module();out=io.StringIO()
        with patch.object(module.sys,'argv',['runner','--build-only','--boot-only']),contextlib.redirect_stderr(out):
            with self.assertRaises(SystemExit) as raised:module.main()
        self.assertEqual(raised.exception.code,2)
        self.assertIn('not allowed with argument',out.getvalue())

    @unittest.skipUnless(sys.platform=='darwin','installed Apple libc control requires Darwin')
    def test_native_libc_unbuffered_request_exposes_output_before_exit(self):
        # Regular file, no newline/fflush/normal exit: observe libc itself, not
        # Python stdout or a terminal. Lack of support is explicitly unverified.
        import select
        command="import ctypes,os,sys; ctypes.CDLL(None).printf(b'IOS_LIBC_BUFFER_CONTROL'); os.write(int(sys.argv[1]),b'R'); os.read(int(sys.argv[2]),1)"
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'libc-control.log'
            ready_read,ready_write=os.pipe();ack_read,ack_write=os.pipe()
            with path.open('wb') as output:
                process=subprocess.Popen([sys.executable,'-c',command,str(ready_write),str(ack_read)],
                    stdout=output,stderr=subprocess.STDOUT,pass_fds=(ready_write,ack_read),
                    env=dict(os.environ,STDBUF1='0',_STDBUF_O='0'))
                os.close(ready_write);os.close(ack_read)
                try:
                    if not select.select([ready_read],[],[],2)[0]:
                        print('IOS_STARTUP_NATIVE_LIBC_BUFFER_CONTROL=unverified_ready_timeout',flush=True)
                        self.skipTest('libc control readiness exceeded diagnostic budget')
                    self.assertEqual(os.read(ready_read,1),b'R')
                    self.assertIsNone(process.poll(),'control must still be alive; exit flush proves nothing')
                    if b'IOS_LIBC_BUFFER_CONTROL' not in path.read_bytes():
                        print('IOS_STARTUP_NATIVE_LIBC_BUFFER_CONTROL=unverified',flush=True)
                        self.skipTest('Apple libc unbuffered override not observed before exit')
                    print('IOS_STARTUP_NATIVE_LIBC_BUFFER_CONTROL=observed_before_exit',flush=True)
                finally:
                    # Keep it blocked until observation; no normal-exit flush
                    # can satisfy the assertion above.
                    try:os.write(ack_write,b'A')
                    except BrokenPipeError:pass
                    os.close(ready_read);os.close(ack_write)
                    if process.poll() is None:process.kill()
                    process.wait(timeout=3)

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
