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

def sample_owned_processes(process,directory,command):
    if sys.platform!='darwin' or Path(command[0]).name!='xcodebuild':return
    derived_data=Path(command[command.index('-derivedDataPath')+1]) if '-derivedDataPath' in command else None
    listing=subprocess.run(['ps','-axo','pid=,ppid=,pgid=,pcpu=,etime=,rss=,command='],
        capture_output=True,text=True,timeout=5,check=False).stdout
    owned=owned_process_rows(listing,process.pid,derived_data)
    print('IOS_STARTUP_OWNED_PROCESS_STATE='+json.dumps(owned[:24]),flush=True)
    candidates=[str(process.pid)]+[row[0] for row in owned if 'swift-frontend' in row[6]][:1]
    for pid in candidates:
        sample=directory/('owned-sample-'+pid+'.txt')
        try:subprocess.run(['sample',pid,'2','1','-file',str(sample)],
            stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT,timeout=8,check=False)
        except subprocess.TimeoutExpired:continue
        if sample.exists():print(bounded_log(sample).decode('utf-8','replace'),flush=True)

def group_has_executing_members(pgid):
    result=subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,timeout=3,check=True)
    if not result.stdout.strip():raise RuntimeError('Empty process-group inventory')
    states=[]
    for line in result.stdout.splitlines():
        if not line.strip():continue
        fields=line.split()
        if len(fields)!=3 or not fields[0].isdigit() or not fields[1].isdigit():raise RuntimeError('Ambiguous process-group inventory')
        if fields[1]==str(pgid):states.append(fields[2])
    print('IOS_STARTUP_GROUP_STATES='+json.dumps({'pgid':pgid,'states':states}),flush=True)
    return any(not state.startswith('Z') for state in states)

def signal_group_or_retired(pgid,sig):
    try:os.killpg(pgid,sig);return True
    except ProcessLookupError:return False
    except PermissionError:
        # Darwin killpg1 skips zombies and may return EPERM for a zombie-only
        # group. Never equate EPERM with retirement without fresh OS evidence.
        if not group_has_executing_members(pgid):return False
        raise

def retire_owned_group(process,graces=((signal.SIGINT,10),(signal.SIGTERM,5),(signal.SIGKILL,5))):
    for sig,grace in graces:
        if not signal_group_or_retired(process.pid,sig):break
        # Reap the leader without mistaking its exit for group retirement.
        deadline=time.monotonic()+grace
        while time.monotonic()<deadline:
            process.poll()
            if not signal_group_or_retired(process.pid,0):break
            time.sleep(0.05)
        else:continue
        break
    process.wait(timeout=5)
    if group_has_executing_members(process.pid):
        raise RuntimeError('Owned process group still has executing descendants')

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
                retire_owned_group(process)
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
        with path.open('wb') as output:
            try:subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,timeout=timeout,check=False)
            except subprocess.TimeoutExpired:print('IOS_STARTUP_DIAGNOSTIC_TIMEOUT',flush=True)
        with path.open('rb') as source:
            source.seek(max(0,path.stat().st_size-16384))
            print(source.read(16384).decode('utf-8','replace'),flush=True)
    def diagnostics():
        small(['xcrun','simctl','list','devices','booted','-j'])
        # Only current selected-simulator app/runner processes are sampled.
        listing=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True,timeout=5).stdout
        sampled=0
        for line in listing.splitlines():
            parts=line.strip().split(None,1)
            if len(parts)!=2 or args.simulator.lower() not in parts[1].lower():continue
            if not re.search(r'/(VPlayer|VPlayeriOSUITests-Runner)(?:\s|$)',parts[1]):continue
            if sampled>=2:break
            sampled+=1
            print('IOS_STARTUP_SCOPED_PROCESS_PID='+parts[0],flush=True)
            sample=directory/('sample-'+parts[0]+'.txt')
            small(['sample',parts[0],'2','1','-file',str(sample)],timeout=8)
            if sample.exists():print(sample.read_text(errors='replace')[:16384],flush=True)
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
