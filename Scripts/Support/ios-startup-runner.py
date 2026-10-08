#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Bounded Release XCTest sentinel/startup diagnostics; never changes app policy."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shlex
import subprocess
import sys
import tempfile
import time

FACT_KEYS={'TestBundlePath','TestHostPath','UITargetAppPath','UITargetAppBundleIdentifier',
           'OnlyTestIdentifiers','SkipTestIdentifiers','IsUITestBundle','BlueprintName'}
def artifact_facts(value):
    result=[]
    if isinstance(value,dict):
        facts={k:v for k,v in value.items() if k in FACT_KEYS}
        if facts:result.append(facts)
        for key,child in value.items():
            if key not in {'EnvironmentVariables','TestingEnvironmentVariables'}:
                result.extend(artifact_facts(child))
    elif isinstance(value,list):
        for child in value:result.extend(artifact_facts(child))
    return result

def startup_completed(data):
    required=[b'IOS_RELEASE_STARTUP_TEST_ENTER']
    for index in range(3):
        required.extend([f'IOS_RELEASE_LIBRARY_READY index={index} ready=true'.encode(),
                         f'IOS_RELEASE_TERMINATE_RETURNED index={index}'.encode()])
    return all(marker in data for marker in required)

def bounded_log(path):
    with path.open('rb') as source:
        head=source.read(8192)
        source.seek(max(len(head),path.stat().st_size-16384))
        return head+b'\nIOS_LOG_TAIL\n'+source.read(16384)

def owned_process_rows(listing,pid,derived_data):
    owned=[]
    for line in listing.splitlines():
        fields=line.strip().split(None,6)
        if len(fields)!=7:continue
        try:arguments=shlex.split(fields[6])
        except ValueError:continue
        if not arguments:continue
        compiler=Path(arguments[0]).name in {'swift-frontend','swift-driver','swiftc'}
        matching_output=derived_data is not None and any(
            argument.startswith(str(derived_data)+'/') for argument in arguments[1:])
        if fields[2]==str(pid) or (compiler and matching_output):
            owned.append(fields[:6]+[arguments[0]])
    return owned

def native_ps_environment():
    # Darwin legacy mode ignores -g; keep the override local to these reads.
    return dict(os.environ, COMMAND_MODE='unix2003', LC_ALL='C')

def sample_owned_processes(process,directory,command):
    if sys.platform!='darwin':return
    build=Path(command[0]).name=='xcodebuild'
    boot=(len(command)>2 and Path(command[0]).name=='xcrun'
          and command[1]=='simctl' and command[2] in {'boot','bootstatus'})
    if not (build or boot):return
    def sample_pid(pid):
        print('IOS_STARTUP_PROCESS_SAMPLE_PID='+str(pid),flush=True)
        sample=directory/('owned-sample-'+str(pid)+'.txt')
        diagnostic=directory/('sample-command-'+str(pid)+'.log')
        with diagnostic.open('wb') as output:
            try:
                result=subprocess.run(['sample',str(pid),'2','1','-file',str(sample)],
                    stdout=output,stderr=subprocess.STDOUT,timeout=8,check=False)
            except subprocess.TimeoutExpired:
                print('IOS_STARTUP_PROCESS_SAMPLE_TIMEOUT='+str(pid),flush=True)
                return
            except OSError as error:
                print('IOS_STARTUP_PROCESS_SAMPLE_ERROR='+json.dumps({'pid':pid,'error':type(error).__name__,'errno':error.errno}),flush=True)
                return
        if result.returncode:
            print('IOS_STARTUP_PROCESS_SAMPLE_FAILED='+json.dumps({'pid':pid,'exit':result.returncode}),flush=True)
            print(bounded_log(diagnostic).decode('utf-8','replace'),flush=True)
        if sample.exists():print(bounded_log(sample).decode('utf-8','replace'),flush=True)
    # Obtain the known, owned PID's stack before any process enumeration or
    # CoreSimulator IPC. This also distinguishes xcrun resolution from simctl.
    sample_pid(process.pid)
    if not build:return
    derived_data=Path(command[command.index('-derivedDataPath')+1]) if '-derivedDataPath' in command else None
    result=subprocess.run(['/bin/ps','-g',str(process.pid),'-o','pid=,ppid=,pgid=,pcpu=,etime=,rss=,command='],
        env=native_ps_environment(),capture_output=True,text=True,timeout=5,check=False)
    if result.returncode or result.stderr:
        print('IOS_STARTUP_SCOPED_PROCESS_QUERY_FAILED='+json.dumps({'pgid':process.pid,'exit':result.returncode}),flush=True)
        print(result.stderr[:2048],flush=True)
        return
    owned=owned_process_rows(result.stdout,process.pid,derived_data)
    print('IOS_STARTUP_OWNED_PROCESS_STATE='+json.dumps(owned[:24]),flush=True)
    # Service-spawned compiler processes outside this owned group are not
    # enumerated or claimed retired; no global ps dependency in native diagnosis.
    for row in owned:
        if 'swift-frontend' in row[6] and row[0]!=str(process.pid):
            sample_pid(row[0]);break

def group_has_executing_members(pgid,timeout=3,require_leader=False):
    darwin=sys.platform=='darwin'
    command=(['/bin/ps','-g',str(pgid),'-o','pid=,pgid=,stat='] if darwin
             else ['ps','-axo','pid=,pgid=,stat='])
    try:
        result=subprocess.run(command,env=native_ps_environment(),capture_output=True,
            text=True,timeout=timeout,check=False)
    except (OSError,subprocess.SubprocessError) as error:
        print('IOS_STARTUP_GROUP_QUERY_FAILED='+json.dumps({'pgid':pgid,'error':type(error).__name__}),flush=True)
        raise
    if len(result.stdout)>65536 or len(result.stderr)>8192:
        raise RuntimeError('Process-group inventory exceeded its bound')
    # Darwin ps exits 1 when its exact selector matches no processes. A sysctl
    # error may instead exit 0 with stderr, so neither exit alone proves absence.
    if darwin and result.returncode==1 and not result.stdout.strip() and not result.stderr.strip():
        if require_leader:raise RuntimeError('Pinned leader missing from process-group inventory')
        print('IOS_STARTUP_GROUP_STATES='+json.dumps({'pgid':pgid,'states':[]}),flush=True)
        return False
    if result.returncode or result.stderr.strip() or not result.stdout.strip():
        print('IOS_STARTUP_GROUP_QUERY_FAILED='+json.dumps({'pgid':pgid,'exit':result.returncode,
            'stderr':result.stderr[:512]}),flush=True)
        raise RuntimeError('Unverified process-group inventory')
    states=[]
    pids=set()
    group_pids=set()
    for line in result.stdout.splitlines():
        if not line.strip():continue
        fields=line.split()
        if (len(fields)!=3 or not fields[0].isdigit() or not fields[1].isdigit()
                or not re.fullmatch(r'[IRSDTtUZXPWKH][A-Za-z0-9<>+\-]{0,15}',fields[2])):
            raise RuntimeError('Ambiguous process-group inventory')
        if fields[0] in pids:raise RuntimeError('Duplicate PID in process-group inventory')
        pids.add(fields[0])
        if darwin and fields[1]!=str(pgid):
            raise RuntimeError('Scoped process-group inventory returned another group')
        if fields[2].startswith('Z') and not re.fullmatch(r'Z[<>+AELNSsVWXl]*',fields[2]):
            raise RuntimeError('Ambiguous zombie process state')
        if fields[1]==str(pgid):
            states.append(fields[2]);group_pids.add(fields[0])
    if require_leader and str(pgid) not in group_pids:
        raise RuntimeError('Pinned leader missing from process-group inventory')
    print('IOS_STARTUP_GROUP_STATES='+json.dumps({'pgid':pgid,'states':states[:24],'count':len(states)}),flush=True)
    return any(not state.startswith('Z') for state in states)

def signal_group_or_retired(pgid,sig,deadline=None,require_leader=False):
    try:os.killpg(pgid,sig);return True
    except ProcessLookupError:return False
    except PermissionError:
        # Darwin may report EPERM for zombies. A scoped Z-only observation is
        # necessary, but is not atomic: corroborate it with another kernel probe.
        remaining=3 if deadline is None else min(3,deadline-time.monotonic())
        if remaining<=0:raise
        if group_has_executing_members(pgid,timeout=remaining,require_leader=require_leader):raise
        if deadline is not None and time.monotonic()>=deadline:raise
        try:os.killpg(pgid,0)
        except (ProcessLookupError,PermissionError):return False
        return True

def retire_owned_group(process,graces=((signal.SIGINT,10),(signal.SIGTERM,5),(signal.SIGKILL,5))):
    if getattr(process,'returncode',None) is not None:
        raise RuntimeError('Session leader already reaped; group identity is unverified')
    # Keep the session leader unreaped until the last group observation/signal.
    # This pins numerical identity during cleanup; do not use Popen.poll here.
    retired=False
    uncertainty=None
    for sig,grace in graces:
        deadline=time.monotonic()+grace
        if not signal_group_or_retired(process.pid,sig,deadline=deadline,require_leader=True):
            retired=True;break
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0:break
            if sys.platform=='darwin':
                # Success indicates signalable members: never let a ps-only
                # observation override it. EPERM needs corroborated Z evidence.
                # Permission/unknown evidence propagates without alternate signals.
                alive=signal_group_or_retired(process.pid,0,deadline=deadline,require_leader=True)
            else:
                # Linux killpg(0) also counts zombies; use its separate bounded
                # process-state observation while the leader's identity is pinned.
                try:
                    alive=group_has_executing_members(process.pid,timeout=min(3,remaining),require_leader=True)
                    uncertainty=None
                except (OSError,RuntimeError,subprocess.SubprocessError) as error:
                    uncertainty=error
                    remaining=deadline-time.monotonic()
                    if remaining>0:time.sleep(remaining)
                    break
            if not alive:
                retired=True;break
            remaining=deadline-time.monotonic()
            if remaining<=0:break
            time.sleep(min(0.25,remaining))
        if retired:break
    if not retired:
        raise RuntimeError('Owned process-group retirement unverified; executing descendants may remain') from uncertainty
    # This is bounded observed retirement evidence, not an atomic kernel snapshot
    # or a supervisor for arbitrary fork/exit chains. Consume it once before reap;
    # no later PID/PGID query or signal can target a reused numerical identity.
    process.wait(timeout=5)

def run_command(label,command,timeout,directory,diagnostics):
    path=directory/(label+'.log')
    print('IOS_STARTUP_PHASE_BEGIN='+label,flush=True)
    expired=False
    before_interrupt=b''
    with path.open('wb') as output:
        process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            expired=True
            try:
                print('IOS_STARTUP_PHASE_TIMEOUT='+label,flush=True)
                before_interrupt=b'IOS_LOG_PRE_INTERRUPT\n'+bounded_log(path)
                print(before_interrupt.decode('utf-8','replace'),flush=True)
                sample_owned_processes(process,directory,command)
                diagnostics()
            except Exception as error:
                print('IOS_STARTUP_DIAGNOSTIC_FAILED='+type(error).__name__,flush=True)
            finally:
                try:
                    retire_owned_group(process)
                except (OSError,RuntimeError,subprocess.SubprocessError) as error:
                    print('IOS_STARTUP_CLEANUP_UNVERIFIED='+type(error).__name__,flush=True)
                else:
                    print('IOS_STARTUP_CLEANUP_VERIFIED=1',flush=True)
            code=124
    markers=bytearray()
    with path.open('rb') as source:
        for line in source:
            if (b'IOS_RELEASE_' in line or re.search(rb'(?:^|\s)(?:fatal )?error:',line)) and len(markers)<32768:
                markers.extend(line[:32768-len(markers)])
        source.seek(max(0,source.tell()-16384))
        tail=source.read(16384)
    data=before_interrupt+bytes(markers)+tail
    print(data.decode('utf-8','replace'),flush=True)
    print(f'IOS_STARTUP_PHASE_END={label} exit={code} timed_out={expired}',flush=True)
    return code,data

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--simulator',required=True)
    parser.add_argument('--derived-data',required=True,type=Path)
    parser.add_argument('--build-only',action='store_true')
    args=parser.parse_args()
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}',args.simulator):parser.error('exact simulator UUID required')
    directory=Path(tempfile.mkdtemp(prefix='vplayer-ios-startup-'))
    def small(command,timeout=15):
        path=directory/'diagnostic.log'
        succeeded=False
        with path.open('wb') as output:
            try:
                result=subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,timeout=timeout,check=False)
                succeeded=result.returncode==0
                if not succeeded:print('IOS_STARTUP_DIAGNOSTIC_EXIT='+str(result.returncode),flush=True)
            except subprocess.TimeoutExpired:print('IOS_STARTUP_DIAGNOSTIC_TIMEOUT',flush=True)
        with path.open('rb') as source:
            source.seek(max(0,path.stat().st_size-16384))
            print(source.read(16384).decode('utf-8','replace'),flush=True)
        return succeeded
    def diagnostics():
        if not small(['xcrun','simctl','list','devices','booted','-j']):return
        small(['xcrun','simctl','spawn',args.simulator,'log','show','--last','2m','--style','compact',
               '--predicate','process == "VPlayer" OR process == "VPlayeriOSUITests-Runner" OR process == "testmanagerd"'])
    overall_deadline=time.monotonic()+17*60
    def run(label,command,timeout):
        remaining=overall_deadline-time.monotonic()-60
        if remaining<=0:
            diagnostics();return 124,b''
        return run_command(label,command,min(timeout,remaining),directory,diagnostics)
    inventory=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j'],timeout=15))
    matches=[(runtime,device) for runtime,group in inventory['devices'].items() for device in group
             if device.get('udid','').lower()==args.simulator.lower() and device.get('isAvailable')]
    if len(matches)!=1 or 'iOS-27-0' not in matches[0][0] or not matches[0][1]['name'].startswith('iPhone'):
        raise SystemExit('Selected destination is not an available iOS27 iPhone simulator')
    runtime,device=matches[0]
    print('IOS_STARTUP_SIMULATOR='+json.dumps({k:device.get(k) for k in ['name','udid','state']}|{'runtime':runtime}),flush=True)
    build_common=['-project','VPlayer.xcodeproj','-scheme','VPlayeriOSReleaseStartup',
                  '-configuration','Release','-derivedDataPath',str(args.derived_data),
                  'CODE_SIGNING_ALLOWED=NO']
    if args.build_only:
        code,_=run('build',['xcodebuild','build-for-testing']+build_common+[
            '-destination','generic/platform=iOS Simulator'],480)
        return code
    common=['-project','VPlayer.xcodeproj','-scheme','VPlayeriOSReleaseStartup','-configuration','Release',
            '-destination','platform=iOS Simulator,id='+args.simulator,'-derivedDataPath',str(args.derived_data),
            'CODE_SIGNING_ALLOWED=NO','-parallel-testing-enabled','NO','-collect-test-diagnostics','never',
            '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','120',
            '-maximum-test-execution-time-allowance','300']
    if device['state']!='Booted':
        code,_=run('boot',['xcrun','simctl','boot',args.simulator],30)
        if code:return code
    code,_=run('bootstatus',['xcrun','simctl','bootstatus',args.simulator,'-b'],120)
    if code:return code
    for path in sorted((args.derived_data/'Build/Products').glob('*.xctestrun')):
        print('IOS_STARTUP_XCTESTRUN='+json.dumps(artifact_facts(plistlib.loads(path.read_bytes()))),flush=True)
    sentinel='VPlayeriOSUITests/IOSReleaseStartupTests/testRunnerControlWithoutAppLaunch'
    code,data=run('runner-control',['xcodebuild','test-without-building']+common+[
        '-only-testing:'+sentinel,'-resultBundlePath',str(args.derived_data.parent/'iOS-RunnerControl.xcresult')],300)
    if code:return code
    if b'IOS_RELEASE_RUNNER_CONTROL_PASS' not in data:
        print('IOS_STARTUP_SENTINEL_MARKER_MISSING',flush=True);return 1
    selector='VPlayeriOSUITests/IOSReleaseStartupTests/testReleaseIgnoresSeededFixtureAcrossThreeColdStarts'
    code,data=run('app-startup',['xcodebuild','test-without-building']+common+[
        '-only-testing:'+selector,'-resultBundlePath',str(args.derived_data.parent/'iOS-Release.xcresult')],300)
    if code==0 and not startup_completed(data):
        print('IOS_STARTUP_COLD_START_MARKERS_MISSING',flush=True);return 1
    return code
if __name__=='__main__':sys.exit(main())
