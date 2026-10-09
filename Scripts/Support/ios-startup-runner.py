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

def diagnostic_remaining(deadline,maximum):
    remaining=maximum if deadline is None else min(maximum,deadline-time.monotonic())
    if remaining<=0:print('IOS_STARTUP_DIAGNOSTIC_BUDGET_EXHAUSTED=1',flush=True)
    return max(0,remaining)

def host_load_facts(context):
    # Load averages provide scheduling context, not instantaneous CPU utilization.
    try:
        one,five,fifteen=os.getloadavg()
        print('IOS_STARTUP_HOST_LOAD='+json.dumps({'context':context,'cpu_count':os.cpu_count(),
            'loadavg_1m':one,'loadavg_5m':five,'loadavg_15m':fifteen}),flush=True)
    except OSError as error:
        print('IOS_STARTUP_HOST_LOAD_UNAVAILABLE='+json.dumps({'context':context,'errno':error.errno}),flush=True)

def native_process_identity(pid):
    # Called only in the bounded diagnostic child, never in the supervisor.
    # Apple libproc.h/libproc.c: both APIs are int(int, void *, uint32_t).
    # No task port, command arguments, environment, or process enumeration.
    import ctypes
    import errno
    if sys.platform!='darwin' or pid<=0:return 1
    try:library=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    except OSError as error:
        print('IOS_STARTUP_PROCESS_IDENTITY_ERROR='+json.dumps({'pid':pid,'errno':error.errno}),flush=True)
        return 1
    available=False
    for api in ['proc_name','proc_pidpath']:
        print('IOS_STARTUP_PROCESS_IDENTITY_BEGIN='+json.dumps({'pid':pid,'api':api}),flush=True)
        function=getattr(library,api)
        function.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
        function.restype=ctypes.c_int
        buffer=ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        result=function(pid,buffer,len(buffer))
        error=ctypes.get_errno()
        value=buffer.value.decode('utf-8','replace') if 0<result<len(buffer) else None
        print('IOS_STARTUP_PROCESS_IDENTITY='+json.dumps({'pid':pid,'api':api,
            'result':result,'errno':error,'value':value}),flush=True)
        if error in {errno.EPERM,errno.EACCES}:return 77
        available=available or value is not None
    # Separate records preserve possible exec transitions; neither proves health.
    return 0 if available else 1

def emit_diagnostic_file(path):
    try:
        if path.exists():print(bounded_log(path).decode('utf-8','replace'),flush=True)
    except OSError as error:
        print('IOS_STARTUP_DIAGNOSTIC_FILE_ERROR='+json.dumps({'file':path.name,'errno':error.errno}),flush=True)

def observe_owned_identity(process,directory,deadline):
    remaining=diagnostic_remaining(deadline,2)
    if not remaining:return
    path=directory/('owned-identity-'+str(process.pid)+'.log')
    # Static source and PID argv; this child does not fork or create a new group.
    code="import runpy,sys; scope=runpy.run_path(sys.argv[1]); sys.exit(scope['native_process_identity'](int(sys.argv[2])))"
    try:
        with path.open('wb') as output:
            result=subprocess.run([sys.executable,'-c',code,str(Path(__file__).resolve()),str(process.pid)],
                stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=remaining,check=False)
        print('IOS_STARTUP_PROCESS_IDENTITY_EXIT='+json.dumps({'pid':process.pid,'exit':result.returncode}),flush=True)
        if result.returncode==77:return False
    except subprocess.TimeoutExpired:
        print('IOS_STARTUP_PROCESS_IDENTITY_TIMEOUT='+str(process.pid),flush=True)
    except OSError as error:
        print('IOS_STARTUP_PROCESS_IDENTITY_ERROR='+json.dumps({'pid':process.pid,'errno':error.errno}),flush=True)
        if isinstance(error,PermissionError):return False
    finally:emit_diagnostic_file(path)
    return True

def sample_owned_processes(process,directory,command,deadline=None):
    if sys.platform!='darwin':return
    build=Path(command[0]).name=='xcodebuild'
    boot=(len(command)>2 and Path(command[0]).name=='xcrun'
          and command[1]=='simctl' and command[2] in {'boot','bootstatus'})
    if not (build or boot):return
    def sample_pid(pid):
        remaining=diagnostic_remaining(deadline,8)
        if not remaining:return
        print('IOS_STARTUP_PROCESS_SAMPLE_PID='+str(pid),flush=True)
        sample=directory/('owned-sample-'+str(pid)+'.txt')
        diagnostic=directory/('sample-command-'+str(pid)+'.log')
        try:
            with diagnostic.open('wb') as output:
                result=subprocess.run(['sample',str(pid),'2','1','-file',str(sample)],
                    stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=remaining,check=False)
            if result.returncode:
                print('IOS_STARTUP_PROCESS_SAMPLE_FAILED='+json.dumps({'pid':pid,'exit':result.returncode}),flush=True)
        except subprocess.TimeoutExpired:
            print('IOS_STARTUP_PROCESS_SAMPLE_TIMEOUT='+str(pid),flush=True)
        except OSError as error:
            print('IOS_STARTUP_PROCESS_SAMPLE_ERROR='+json.dumps({'pid':pid,'error':type(error).__name__,'errno':error.errno}),flush=True)
        finally:
            # A timed-out sampler may already have useful stderr or stack data.
            emit_diagnostic_file(diagnostic)
            emit_diagnostic_file(sample)
    if observe_owned_identity(process,directory,deadline) is False:return
    sample_pid(process.pid)
    if not build:return
    remaining=diagnostic_remaining(deadline,5)
    if not remaining:return
    derived_data=Path(command[command.index('-derivedDataPath')+1]) if '-derivedDataPath' in command else None
    result=subprocess.run(['/bin/ps','-g',str(process.pid),'-o','pid=,ppid=,pgid=,pcpu=,etime=,rss=,command='],
        env=native_ps_environment(),capture_output=True,text=True,timeout=remaining,check=False)
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
    environment=None
    if (sys.platform=='darwin' and len(command)>2 and Path(command[0]).name=='xcrun'
            and command[1:3]==['simctl','bootstatus']):
        # Apple libc makebuf.c supports both overrides; request only for this
        # child. simctl may override stdio itself, so empty output stays unknown.
        environment=dict(os.environ,STDBUF1='0',_STDBUF_O='0')
        print('IOS_STARTUP_CHILD_STDOUT_BUFFERING=apple_libc_unbuffered_requested',flush=True)
    with path.open('wb') as output:
        process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True,env=environment)
        try:code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            expired=True
            diagnostic_deadline=time.monotonic()+25
            try:
                print('IOS_STARTUP_PHASE_TIMEOUT='+label,flush=True)
                host_load_facts('timeout-'+label)
                before_interrupt=b'IOS_LOG_PRE_INTERRUPT\n'+bounded_log(path)
                print(before_interrupt.decode('utf-8','replace'),flush=True)
                sample_owned_processes(process,directory,command,deadline=diagnostic_deadline)
                diagnostics(diagnostic_deadline)
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
    parser.add_argument('--simulator')
    parser.add_argument('--derived-data',type=Path)
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--build-only',action='store_true')
    modes.add_argument('--boot-only',action='store_true')
    args=parser.parse_args()
    if not args.boot_only and (not args.simulator or not args.derived_data):
        parser.error('--simulator and --derived-data are required outside --boot-only')
    if args.simulator and not re.fullmatch(r'[0-9A-Fa-f-]{36}',args.simulator):parser.error('exact simulator UUID required')
    def boot_result(outcome,phase,code):
        print('IOS_BOOT_PROBE_RESULT='+json.dumps({'outcome':outcome,'phase':phase,'exit':code}),flush=True)
        return code
    if args.boot_only:
        print('IOS_BOOT_PROBE_DIAGNOSTIC_ONLY=true',flush=True)
        print('IOS_BOOT_PROBE_APP_AND_XCTEST=not_run',flush=True)
    directory=Path(tempfile.mkdtemp(prefix='vplayer-ios-startup-'))
    resolved_simctl=None
    def small(command,deadline,timeout=15):
        timeout=diagnostic_remaining(deadline,timeout)
        if not timeout:return False
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
    def diagnostics(deadline):
        prefix=[resolved_simctl] if resolved_simctl else ['xcrun','simctl']
        print('IOS_STARTUP_DIAGNOSTIC_SIMCTL='+('resolved_absolute' if resolved_simctl else 'xcrun_unresolved'),flush=True)
        if not small(prefix+['list','devices','booted','-j'],deadline):return
        small(['xcrun','simctl','spawn',args.simulator,'log','show','--last','2m','--style','compact',
               '--predicate','process == "VPlayer" OR process == "VPlayeriOSUITests-Runner" OR process == "testmanagerd"'],deadline)
    overall_deadline=time.monotonic()+(4*60 if args.boot_only else 17*60)
    def run(label,command,timeout):
        remaining=overall_deadline-time.monotonic()-60
        if remaining<=0:
            diagnostics(time.monotonic()+25);return 124,b''
        return run_command(label,command,min(timeout,remaining),directory,diagnostics)
    inventory=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j'],timeout=15))
    runtime_id='com.apple.CoreSimulator.SimRuntime.iOS-27-0'
    if args.boot_only and not args.simulator:
        candidates=[device for device in inventory['devices'].get(runtime_id,[])
                    if device.get('isAvailable') and device.get('name','').startswith('iPhone')
                    and device.get('state')=='Shutdown']
        if not candidates:return boot_result('unverified_no_shutdown_device','selection',1)
        args.simulator=candidates[0].get('udid','')
        if not re.fullmatch(r'[0-9A-Fa-f-]{36}',args.simulator):
            return boot_result('unverified_device_identifier','selection',1)
    matches=[(runtime,device) for runtime,group in inventory['devices'].items() for device in group
             if device.get('udid','').lower()==args.simulator.lower() and device.get('isAvailable')]
    if len(matches)!=1 or 'iOS-27-0' not in matches[0][0] or not matches[0][1]['name'].startswith('iPhone'):
        raise SystemExit('Selected destination is not an available iOS27 iPhone simulator')
    runtime,device=matches[0]
    print('IOS_STARTUP_SIMULATOR='+json.dumps({k:device.get(k) for k in ['name','udid','state']}|{'runtime':runtime}),flush=True)
    if args.boot_only:
        if runtime!=runtime_id:return boot_result('unverified_runtime','selection',1)
        if device.get('state')!='Shutdown':return boot_result('unverified_non_shutdown','selection',1)
        code,_=run('first-launch-status',['xcodebuild','-checkFirstLaunchStatus'],10)
        print('IOS_BOOT_PROBE_FIRST_LAUNCH_STATUS='+json.dumps({'exit':code}),flush=True)
        if code==124:return boot_result('unverified_preflight_timeout','first-launch-status',code)
    build_common=['-project','VPlayer.xcodeproj','-scheme','VPlayeriOSReleaseStartup',
                  '-configuration','Release','-derivedDataPath',str(args.derived_data),
                  'CODE_SIGNING_ALLOWED=NO']
    if args.build_only:
        code,_=run('build',['xcodebuild','build-for-testing']+build_common+[
            '-destination','generic/platform=iOS Simulator'],480)
        return code
    code,data=run('resolve-simctl',['/usr/bin/xcrun','--find','simctl'],5)
    try:candidate=data.decode('utf-8').strip()
    except UnicodeDecodeError:candidate=''
    if (code==0 and 0<len(candidate)<=4096 and len(candidate.splitlines())==1
            and '\x00' not in candidate and Path(candidate).is_absolute() and Path(candidate).name=='simctl'):
        resolved_simctl=candidate
    print('IOS_STARTUP_SIMCTL_RESOLUTION='+json.dumps({'exit':code,'path':resolved_simctl,
        'result':'resolved_absolute' if resolved_simctl else 'unverified'}),flush=True)
    host_load_facts('pre-boot')
    if device['state']!='Booted':
        code,_=run('boot',['xcrun','simctl','boot',args.simulator],30)
        if code:return boot_result('failed','boot',code) if args.boot_only else code
    if args.boot_only and overall_deadline-time.monotonic()-60<120:
        return boot_result('unverified_budget_exhausted','bootstatus',124)
    code,_=run('bootstatus',['xcrun','simctl','bootstatus',args.simulator,'-b'],120)
    if args.boot_only:return boot_result('boot_ready' if code==0 else 'failed','bootstatus',code)
    if code:return code
    common=['-project','VPlayer.xcodeproj','-scheme','VPlayeriOSReleaseStartup','-configuration','Release',
            '-destination','platform=iOS Simulator,id='+args.simulator,'-derivedDataPath',str(args.derived_data),
            'CODE_SIGNING_ALLOWED=NO','-parallel-testing-enabled','NO','-collect-test-diagnostics','never',
            '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','120',
            '-maximum-test-execution-time-allowance','300']
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
