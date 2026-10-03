#!/usr/bin/env python3
"""Native-only compile controls; no app build, linking, execution, or CI dispatch.
Uses a caller module to retain descriptor-to-allocator loads under optimization.
Writes exact commands/hashes at compilation time. No runtime/peak proof.
"""
import argparse, hashlib, json, pathlib, subprocess, sys

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def output(*args): return subprocess.check_output(args,text=True).strip()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=pathlib.Path)
    parser.add_argument('--configuration',required=True,choices=('Debug','Release'))
    parser.add_argument('--flags-json',type=pathlib.Path,help='Reviewed additional flag array; excludes SDK/target/module/action/output/optimization')
    args=parser.parse_args(); source=pathlib.Path(__file__).resolve().parent
    work=args.output.resolve(); work.mkdir(parents=True,exist_ok=False)
    version=output('xcrun','swiftc','--version')
    if version!=(source/'expected-swift-version.txt').read_text().strip(): raise RuntimeError('Pinned compiler mismatch')
    driver=output('xcrun','swift-driver','--version')
    if driver!='swift-driver version: 1.168.6': raise RuntimeError('Pinned swift-driver mismatch')
    sdk=output('xcrun','--sdk','appletvsimulator','--show-sdk-path')
    sdk_version=output('xcrun','--sdk','appletvsimulator','--show-sdk-version')
    if sdk_version not in ('27.0','27.0.0'): raise RuntimeError('Expected the tvOS 27.0 Simulator SDK')
    target='arm64-apple-tvos27.0-simulator'
    optimization='-Onone' if args.configuration=='Debug' else '-O'
    extra=json.loads(args.flags_json.read_text()) if args.flags_json else (['-g','-DDEBUG'] if args.configuration=='Debug' else ['-g'])
    if not isinstance(extra,list) or not all(isinstance(x,str) for x in extra): raise RuntimeError('Flag JSON must contain a string array')
    forbidden={'-target','-sdk','-module-name','-o','-emit-ir','-emit-object','-emit-module','-c','-Onone','-O','-Osize','-Ounchecked'}
    if any(x in forbidden or x.startswith('@') for x in extra): raise RuntimeError('Reserved compiler action/target/optimization flag in extra flags')
    common=['xcrun','swiftc','-target',target,'-sdk',sdk,'-swift-version','6',optimization,
            '-parse-as-library','-module-cache-path',str(work/'module-cache')]+extra
    print(json.dumps(dict(kind='compiler_configuration',compiler=version,driver=driver,
        target=target,sdk_path=sdk,sdk_version=sdk_version,configuration=args.configuration,
        optimization=optimization,common_argv=common)),flush=True)
    commands=[]
    def run(command):
        commands.append(command)
        with (work/'compiler.log').open('a') as log:
            log.write(json.dumps(command)+'\n'); log.flush()
            completed=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=90)
        if completed.returncode:
            print('\n'.join((work/'compiler.log').read_text().splitlines()[-60:]),file=sys.stderr)
            raise RuntimeError('Native compiler failed; no descriptor validation claimed')
    controls=source/'AsyncLayoutControls.swift'; caller=source/'AsyncLayoutCaller.swift'
    module=work/'AsyncLayoutControls.swiftmodule'
    module_command=common+['-module-name','AsyncLayoutControls',str(controls),'-emit-module','-emit-module-path',str(module)]
    run(module_command)
    manifest=dict(schema=1,scope='controls',compiler_version=version,
        driver_version=driver,
        target=target,sdk_path=sdk,sdk_version=sdk_version,configuration=args.configuration,
        optimization=optimization,module_command=module_command,pairs=[])
    for role,name,input_path in [('control','AsyncLayoutControls',controls),('caller','AsyncLayoutCaller',caller)]:
        base=common+['-module-name',name,'-I',str(work),str(input_path)]
        ir=work/(name+'.ll'); obj=work/(name+'.o')
        ir_command=base+['-emit-ir','-o',str(ir)]
        object_command=base+['-emit-object','-o',str(obj)]
        inputs={str(input_path):sha(input_path)}
        if role=='caller': inputs[str(module)]=sha(module)
        run(ir_command); run(object_command)
        manifest['pairs'].append(dict(role=role,ir=str(ir),object=str(obj),
            ir_sha256=sha(ir),object_sha256=sha(obj),ir_argv=ir_command,
            object_argv=object_command,inputs=inputs))
    path=work/'artifact-set.json'; path.write_text(json.dumps(manifest,indent=2)+'\n')
    for pair in manifest['pairs']:
        print(json.dumps(dict(kind='emitted_artifact_pair',**pair)))
    print(json.dumps(dict(kind='controls_emitted',manifest=str(path),configuration=args.configuration,
        target=target,optimization=optimization,validated=False,runtime_or_peak_proven=False)))

if __name__=='__main__':
    try: main()
    except Exception as error:
        print('CONTROL_EMISSION_FAILED: '+str(error),file=sys.stderr); sys.exit(1)
