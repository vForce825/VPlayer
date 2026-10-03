#!/usr/bin/env python3
"""Read-only compiler-frame diagnostic, never a total memory/peak-budget proof.
Requires either a reviewed ABI header or exact final-IR/object artifact pairs,
plus an exact expected xcrun swiftc --version file. Artifact mode is deliberately
narrow and fails unknown forms; synthetic parser tests are not native evidence.
Known declaration shape: swift/ABI/Executor.h, AsyncFunctionPointer with a
32-bit compact Function reference followed by uint32_t ExpectedContextSize.
Primary reference verified separately: swiftlang/swift swift-6.2-RELEASE.
Do not pass that older header as proof for a different pinned compiler.
"""
import argparse, hashlib, json, pathlib, re, struct, subprocess, sys

TARGETS = (
    ('activation', 'AVPlayerItemCoordinator', 'activate('),
    ('coverage_wait', 'LoopbackAVPlayerPreparationEvidenceSource', 'awaitPausedResumeCoverage('),
    ('driver_credit_wait', 'SystemAVPlayerDriver', 'awaitPausedResumeOperationCredit'),
    ('pool_credit_wait', 'AVPlayerSDKCallbackCreditPool', 'waitForOperationReturn('),
)

def fail(message):
    raise RuntimeError(message)

def records(path, fragments=None):
    data = path.read_bytes()
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        fail(f'{path}: expected thin little-endian 64-bit Mach-O object')
    _, cpu, subtype, kind, ncmds, cmdbytes, flags, reserved = struct.unpack_from('<8I', data)
    if kind != 1 or cpu not in (0x0100000c, 0x01000007):
        fail(f'{path}: unsupported object type/architecture {kind}/{cpu:#x}')
    sections=[]; symtab=None; cursor=32; build=None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor+size > len(data): fail(f'{path}: malformed load command')
        if cmd == 2: symtab=struct.unpack_from('<4I',data,cursor+8)
        if cmd == 0x32:
            if size < 24 or build is not None: fail(f'{path}: malformed/duplicate build version')
            build=struct.unpack_from('<3I',data,cursor+8)
        if cmd == 0x19:
            nsects=struct.unpack_from('<I',data,cursor+64)[0]
            for i in range(nsects):
                q=cursor+72+80*i
                name=data[q:q+16].split(b'\0')[0].decode()
                addr,count,offset,align,reloff,nreloc=struct.unpack_from('<QQ4I',data,q+32)
                sections.append((name,addr,count,offset,reloff,nreloc))
        cursor+=size
    if not symtab: fail(f'{path}: no symbol table')
    symoff,nsyms,stroff,strsize=symtab
    def symbol_name(index):
        if not 0 <= index < nsyms: fail(f'{path}: relocation symbol outside table')
        strx=struct.unpack_from('<I',data,symoff+16*index)[0]
        if not strx < strsize: fail(f'{path}: symbol string outside table')
        end=data.find(b'\0',stroff+strx,stroff+strsize)
        if end < 0: fail(f'{path}: unterminated symbol')
        return data[stroff+strx:end].decode()
    for i in range(nsyms):
        strx,typ,section,desc,value=struct.unpack_from('<IBBHQ',data,symoff+16*i)
        if typ & 0xe0 or (typ & 0x0e) != 0x0e or not 1 <= section <= len(sections): continue
        if not strx < strsize: fail(f'{path}: symbol string outside table')
        end=data.find(b'\0',stroff+strx,stroff+strsize)
        if end < 0: fail(f'{path}: unterminated symbol')
        symbol=data[stroff+strx:end].decode()
        if not symbol.startswith('_$s') or not symbol.endswith('Tu'): continue
        if not any(part in symbol for part in (fragments or tuple(t[1] for t in TARGETS))): continue
        name,addr,count,offset,reloff,nreloc=sections[section-1]
        relative=value-addr
        if relative < 0 or relative+8 > count or offset+relative+8 > len(data):
            fail(f'{path}: descriptor outside attributed section: {symbol}')
        # For the only supported external SUBTRACTOR/UNSIGNED expression, the
        # linker computes S_function - S_descriptor + A. Our IR validator
        # requires exactly function - descriptor, so a stored A != 0 changes
        # the target. Do not silently accept function+4 (or guess other forms).
        addend=struct.unpack_from('<i',data,offset+relative)[0]
        if addend != 0:
            fail(f'{path}: unverified first-field relocation addend {addend}: {symbol}')
        first_relocations=[]
        for r in range(nreloc):
            location=struct.unpack_from('<I',data,reloff+8*r)[0]
            if location == relative+4: fail(f'{path}: context size is relocated, cannot attribute {symbol}')
            if location == relative:
                info=struct.unpack_from('<I',data,reloff+8*r+4)[0]
                first_relocations.append(dict(symbol=symbol_name(info & 0xffffff) if (info >> 27) & 1 else None,
                    type=info >> 28, length=(info >> 25) & 3, pcrel=(info >> 24) & 1))
        context_size=struct.unpack_from('<I',data,offset+relative+4)[0]
        if not 16 <= context_size <= 1_048_576:
            fail(f'{path}: implausible context size {context_size} for {symbol}')
        yield dict(object=str(path),cpu=cpu,section=name,symbol=symbol,
                   descriptor_file_offset=offset+relative,expected_context_size=context_size,
                   build_version=build,first_relocations=first_relocations,
                   first_field_addend=addend)

def target_version(target):
    match=re.fullmatch(r'arm64-apple-tvos(\d+)(?:\.(\d+))?(?:\.(\d+))?-simulator',target)
    if not match: fail('Artifact mode supports only an explicit arm64 tvOS Simulator triple')
    return tuple(int(x or 0) for x in match.groups())

def parse_final_ir(ir, target):
    triple=re.search(r'^target triple = "([^"]+)"$',ir,re.M)
    if not triple or target_version(triple[1]) != target_version(target): fail('IR target mismatch')
    if not re.search(r'^%swift\.async_func_pointer = type <\{ i32, i32 \}>$',ir,re.M):
        fail('Unrecognized IR async-function descriptor type')
    if re.search(r'\bcall\b[^\n]*@llvm\.coro\.(?:id|begin|suspend|end)',ir):
        fail('IR still contains unlowered coroutine calls')
    result={}
    for line in ir.splitlines():
        match=re.match(r'^@"([^"\n]+Tu)" = .*\b(?:global|constant) %swift\.async_func_pointer (.*)$',line)
        if not match: continue
        symbol,initializer=match.groups()
        shape=re.fullmatch(r'<\{ i32 trunc \(i64 sub \(i64 ptrtoint \(ptr @"([^"\n]+)" to i64\), i64 ptrtoint \(ptr @"([^"\n]+)" to i64\)\) to i32\), i32 (\d+) \}>(?:, .*)?',initializer)
        if not shape: fail(f'Unrecognized descriptor initializer: {symbol}')
        function,base,size=shape.groups(); size=int(size)
        if base != symbol or not 16 <= size <= 1_048_576: fail(f'Invalid context/base: {symbol}')
        if not re.search(r'^define\b[^\n]*@"'+re.escape(function)+r'"\(',ir,re.M):
            fail(f'Descriptor lacks a matching function definition: {symbol}')
        if symbol in result: fail(f'Duplicate IR descriptor: {symbol}')
        result[symbol]=(function,size)
    return result

def allocator_size_chain(ir, symbol):
    # Deliberately narrow SSA pattern, bounded to one function. Unknown syntax
    # rejects; this is not a general LLVM interpreter or a constant-size guess.
    # Observed optional nuw constrains GEP arithmetic; field/index checks stay exact.
    # Packed i32/i32 has no padding: the observed i8 + 4 form also selects field 1.
    # Require that exact layout before interpreting a byte GEP; guess no offsets.
    packed_layout=re.search(r'^%swift\.async_func_pointer = type <\{ i32, i32 \}>$',ir,re.M)
    for function,body in re.findall(r'^define\b[^\n]*@"([^"\n]+)"[^\n]*\{\n(.*?)^\}',ir,re.M|re.S):
        load=re.search(r'(%[\w.]+) = load i32, ptr getelementptr inbounds(?: nuw)? \(%swift\.async_func_pointer, ptr @"'+re.escape(symbol)+r'", i32 0, i32 1\)',body)
        if not load and packed_layout:
            load=re.search(r'(%[\w.]+) = load i32, ptr getelementptr inbounds nuw \(i8, ptr @"'+re.escape(symbol)+r'", i64 4\)',body)
        if not load: continue
        rest=body[load.end():]
        extend=re.search(r'(%[\w.]+) = zext i32 '+re.escape(load[1])+r' to i64\b',rest)
        if extend and re.search(r'\bcall swiftcc ptr @swift_task_alloc\(i64 '+re.escape(extend[1])+r'\)',rest[extend.end():]):
            return dict(caller_function=function,descriptor=symbol,field_index=1,
                        loaded_i32=load[1],allocator_i64=extend[1])
    return None

def has_allocator_size_chain(ir, symbol):
    return allocator_size_chain(ir,symbol) is not None

def validate_commands(ir_argv, object_argv, target, optimization, ir_path, object_path):
    def normalize(argv, action, output):
        if not isinstance(argv,list) or not all(isinstance(x,str) for x in argv): fail('argv must be a string array')
        if argv[:2] != ['xcrun','swiftc']: fail('Expected recorded xcrun swiftc command')
        if any(x.startswith('@') for x in argv): fail('Expand and review response files before recording this diagnostic')
        if argv.count('-target') != 1 or argv[argv.index('-target')+1] != target: fail('Command target mismatch')
        if argv.count('-sdk') != 1: fail('Exactly one SDK path is required')
        if [x for x in argv if x in ('-Onone','-O','-Osize','-Ounchecked')] != [optimization]: fail('Optimization mismatch')
        if argv.count(action) != 1 or argv.count('-o') != 1 or argv[argv.index('-o')+1] != output: fail('Emission action/output mismatch')
        copy=list(argv); index=copy.index('-o'); del copy[index:index+2]; copy.remove(action)
        if any(x in copy for x in ('-emit-ir','-emit-object','-c','-emit-module')): fail('Multiple emission actions unsupported')
        return copy
    if normalize(ir_argv,'-emit-ir',ir_path) != normalize(object_argv,'-emit-object',object_path):
        fail('IR/object compile commands differ beyond action/output')

def artifact_mode(path, actual):
    manifest=json.loads(path.read_text())
    if manifest.get('schema') != 1 or manifest.get('compiler_version') != actual: fail('Build record compiler/schema mismatch')
    target=manifest['target']; version=target_version(target)
    if version != (27,0,0): fail('This reviewed control is restricted to tvOS 27.0 Simulator')
    # Query the same supported entry point used to compile the artifacts.
    toolchain=subprocess.run(['xcrun','swiftc','--version'],text=True,capture_output=True,check=True)
    if toolchain.stdout.strip()!=actual: fail('Pinned compiler version mismatch')
    driver=toolchain.stderr.strip()
    if driver!='swift-driver version: 1.168.6' or manifest.get('driver_version')!=driver: fail('Pinned driver mismatch')
    sdk_path=subprocess.check_output(['xcrun','--sdk','appletvsimulator','--show-sdk-path'],text=True).strip()
    sdk_version=subprocess.check_output(['xcrun','--sdk','appletvsimulator','--show-sdk-version'],text=True).strip()
    if manifest.get('sdk_path')!=sdk_path or manifest.get('sdk_version')!=sdk_version: fail('Recorded SDK differs from selected SDK')
    optimization=manifest['optimization']; scope=manifest['scope']
    if optimization not in ('-Onone','-O','-Osize') or scope not in ('controls','production'): fail('Unknown optimization/scope')
    if manifest['configuration'] not in ('Debug','Release'): fail('Unknown configuration')
    pairs=manifest['pairs']
    if not 2 <= len(pairs) <= 8: fail('Expected 2..8 artifact pairs')
    rows=[]; controls={}; callers=[]; observed_roles=[]
    for pair in pairs:
        role=pair['role']; observed_roles.append(role)
        if role not in ('control','caller','production'): fail('Unknown artifact role')
        ir_path=pathlib.Path(pair['ir']); object_path=pathlib.Path(pair['object'])
        validate_commands(pair['ir_argv'],pair['object_argv'],target,optimization,str(ir_path),str(object_path))
        if pair['ir_argv'][pair['ir_argv'].index('-sdk')+1] != sdk_path: fail('Compile command SDK mismatch')
        for key,file in [('ir',ir_path),('object',object_path)]:
            if hashlib.sha256(file.read_bytes()).hexdigest() != pair[key+'_sha256']: fail(f'Artifact hash mismatch: {file}')
        inputs=pair['inputs']
        if not inputs: fail('Compile-time input hashes required')
        for name,digest in inputs.items():
            if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() != digest: fail(f'Input hash mismatch: {name}')
        if any(x.endswith('.swift') and x not in inputs for x in pair['ir_argv']): fail('Missing Swift input hash')
        ir=ir_path.read_text(); descriptors=parse_final_ir(ir,target)
        if role == 'caller': callers.append(ir)
        fragments={'control':('controlSmall','controlWide','controlContinuation'),
                   'caller':('callSmall','callWide','callContinuation')}.get(role)
        current=list(records(object_path,fragments))
        if not current: fail(f'No attributable descriptors: {object_path}')
        for row in current:
            symbol=row['symbol'][1:]
            if symbol not in descriptors: fail(f'Object descriptor missing from final IR: {symbol}')
            function,size=descriptors[symbol]
            if row['expected_context_size'] != size: fail(f'IR/object size mismatch: {symbol}')
            if row['cpu'] != 0x0100000c or not row['build_version'] or row['build_version'][0] != 8 or row['build_version'][1] != (version[0]<<16 | version[1]<<8 | version[2]):
                fail(f'Object is not the recorded arm64 tvOS Simulator deployment target: {object_path}')
            expected=[dict(symbol='_'+symbol,type=1,length=2,pcrel=0),dict(symbol='_'+function,type=0,length=2,pcrel=0)]
            if row['first_relocations'] != expected: fail(f'Unverified first-field relocation pair: {symbol}: {row["first_relocations"]}')
            row.update(kind='compiler_frame',role=role,ir_sha256=pair['ir_sha256'],object_sha256=pair['object_sha256'])
            rows.append(row)
    if observed_roles.count('control') != 1 or observed_roles.count('caller') != 1: fail('Exactly one control and caller pair required')
    production=[r for r in rows if r['role']=='production']
    if bool(production) != (scope=='production'): fail('Declared scope does not match production pairs')
    if len(rows)>128: fail('Bounded report exceeded 128 rows; no truncated acceptance')
    names=subprocess.run(['xcrun','swift-demangle','--compact'],input='\n'.join(r['symbol'] for r in rows)+'\n',text=True,capture_output=True,check=True).stdout.splitlines()
    if len(names)!=len(rows): fail('Demangler cardinality mismatch')
    found=set()
    for row,name in zip(rows,names):
        if 'async function pointer to ' not in name: fail(f'Unattributed descriptor: {name}')
        row['demangled']=name
        row['attribution']=[label for label,cls,method in TARGETS if cls in name and method in name]
        if row['role']=='control':
            for control in ('controlSmall','controlWide','controlContinuation'):
                if name.startswith('async function pointer to AsyncLayoutControls.'+control+'('):
                    if control in controls: fail(f'Ambiguous control descriptor: {control}')
                    controls[control]=(row['symbol'][1:],row['expected_context_size'])
        if row['role']=='production' and not any(x in name for x in ('closure #','partial function','protocol witness','thunk')): found.update(row['attribution'])
    if set(controls) != {'controlSmall','controlWide','controlContinuation'}: fail('Missing original control descriptors')
    if controls['controlWide'][1] <= controls['controlSmall'][1]: fail('Large retained-state control did not produce a larger frame')
    linkage=[]
    for symbol,size in controls.values():
        evidence=next((value for ir in callers if (value:=allocator_size_chain(ir,symbol))),None)
        if not evidence: fail(f'Missing descriptor-to-allocator SSA chain: {symbol}')
        linkage.append(dict(kind='allocator_argument_linkage',**evidence))
    if scope=='production' and found != {t[0] for t in TARGETS}: fail('Missing production original functions: '+str(sorted({t[0] for t in TARGETS}-found)))
    print(json.dumps(dict(kind='artifact_local_validation',compiler=actual,target=target,configuration=manifest['configuration'],optimization=optimization,manifest_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),scope=scope)))
    for row in rows: print(json.dumps(row))
    for row in linkage: print(json.dumps(row))
    print(json.dumps(dict(kind='diagnostic_complete',production_attributed=scope=='production',aggregate_or_envelope_proven=False,runtime_slab_cancellation_and_peak_proven=False)))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--abi-header',type=pathlib.Path)
    p.add_argument('--abi-source-url')
    p.add_argument('--artifact-set',type=pathlib.Path,help='Compile-time manifest of exact final IR/object pairs; separate invocation per configuration')
    p.add_argument('--expected-toolchain-version',required=True,type=pathlib.Path)
    p.add_argument('objects',nargs='*',type=pathlib.Path)
    a=p.parse_args()
    actual=subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip()
    if actual != a.expected_toolchain_version.read_text().strip():
        fail('Pinned compiler version mismatch; do not infer ABI compatibility')
    if a.artifact_set:
        if a.abi_header or a.abi_source_url or a.objects: fail('Do not mix header and artifact-local modes')
        return artifact_mode(a.artifact_set,actual)
    if not a.abi_header or not a.abi_source_url or not a.objects: fail('Reviewed ABI header mode or artifact-local mode required')
    header=a.abi_header.read_text()
    declaration=re.search(r'class AsyncFunctionPointer\s*\{(.*?)\n\};',header,re.S)
    if not declaration or not re.search(r'(?:TargetCompactFunctionPointer|RelativeDirectPointer)<.*?int32_t>\s+Function\s*;.*?uint32_t\s+ExpectedContextSize\s*;',declaration[1],re.S):
        fail('ABI declaration not recognized; do not guess descriptor layout')
    print(json.dumps(dict(kind='toolchain',version=actual,abi_source=a.abi_source_url,
        abi_header_sha256=hashlib.sha256(header.encode()).hexdigest(),
        scope='compiler expected context sizes only; excludes runtime allocations, slabs, cancellation records and peak overlap')))
    rows=[]
    for path in a.objects: rows.extend(records(path))
    if not rows: fail('No attributable async-function pointer descriptors found')
    names=subprocess.run(['xcrun','swift-demangle','--compact'],input='\n'.join(r['symbol'] for r in rows)+'\n',
                         text=True,capture_output=True,check=True).stdout.splitlines()
    if len(names) != len(rows): fail('Demangler output cardinality mismatch')
    found=set()
    for row,name in zip(rows,names):
        if 'async function pointer to ' not in name: fail(f'Unattributed descriptor: {row["symbol"]} -> {name}')
        matched=[label for label,cls,method in TARGETS if cls in name and method in name]
        if not matched: continue
        row.update(kind='compiler_frame',demangled=name,attribution=matched)
        if not any(marker in name for marker in ('closure #','partial function','protocol witness','thunk')):
            found.update(matched)
        print(json.dumps(row))
    missing={t[0] for t in TARGETS}-found
    if missing: fail('Missing original function descriptors: '+', '.join(sorted(missing)))
    print(json.dumps(dict(kind='diagnostic_complete',attributed_originals=sorted(found),
        aggregate_or_envelope_proven=False)))

if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('ASYNC_CONTEXT_DIAGNOSTIC_FAILED: '+str(error),file=sys.stderr)
        sys.exit(1)
