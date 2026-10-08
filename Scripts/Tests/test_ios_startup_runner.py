#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import importlib.util
import os
import signal
import time
from pathlib import Path
import sys
import tempfile
import unittest
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
                    with self.assertRaises(ProcessLookupError):os.kill(pid,0)
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
    def test_artifact_projection_excludes_environment_and_only_reports_allowed_keys(self):
        module=self.module()
        value={'EnvironmentVariables':{'TOKEN':'private'},'TestTargets':[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test'], 'Secret':'private'}]}
        projected=module.artifact_facts(value)
        self.assertEqual(projected,[{'UITargetAppPath':'app','OnlyTestIdentifiers':['test']}])
        self.assertNotIn('private',str(projected))
if __name__=='__main__':unittest.main()
