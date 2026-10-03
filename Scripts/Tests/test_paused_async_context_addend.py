"""Independent synthetic parser-only regression. No compilation, CI or repo writes.
Usage: python3 -B Scripts/Tests/test_paused_async_context_addend.py reader.py
Or provide the unapplied patch path (reader source is extracted in memory).
"""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
import contextlib, hashlib, io, json, struct, sys

TARGET='arm64-apple-tvos27.0-simulator'
SDK='/synthetic/SDK'
VERSION='synthetic pinned version'
CONTROLS=[('$scontrolSmallTu','$scontrolSmall',128),('$scontrolWideTu','$scontrolWide',384),('$scontrolContinuationTu','$scontrolContinuation',128)]
CALLERS=[('$scallSmallTu','$scallSmall',128),('$scallWideTu','$scallWide',128),('$scallContinuationTu','$scallContinuation',128)]

def make_object(symbols, addend):
    n=len(symbols); cmdlen=72+80*2+24+24; dataoff=32+cmdlen
    constbytes=b''.join(struct.pack('<iI',addend,size) for _,_,size in symbols)
    textbytes=b'\x00'*4*n; reloff=dataoff+len(constbytes)+len(textbytes)
    relocs=b''.join(struct.pack('<4I',i*8,(1<<28)|(2<<25)|(1<<27)|(i*2),i*8,(2<<25)|(1<<27)|(i*2+1)) for i in range(n))
    syms=[]; strings=bytearray(b'\0')
    for i,(symbol,function,_) in enumerate(symbols):
        for name,section,value in [('_'+symbol,1,i*8),('_'+function,2,len(constbytes)+i*4)]:
            idx=len(strings); strings.extend(name.encode()+b'\0')
            syms.append(struct.pack('<IBBHQ',idx,0xf,section,0,value))
    symoff=reloff+len(relocs); stroff=symoff+len(b''.join(syms))
    header=struct.pack('<8I',0xfeedfacf,0x0100000c,0,1,3,cmdlen,0,0)
    seg=struct.pack('<II16sQQQQIIII',0x19,232,b'',0,len(constbytes)+len(textbytes),dataoff,len(constbytes)+len(textbytes),7,7,2,0)
    section1=struct.pack('<16s16sQQ8I',b'__const',b'__DATA',0,len(constbytes),dataoff,3,reloff,2*n,0,0,0,0)
    section2=struct.pack('<16s16sQQ8I',b'__text',b'__TEXT',len(constbytes),len(textbytes),dataoff+len(constbytes),2,0,0,0,0,0,0)
    symtab=struct.pack('<6I',2,24,symoff,len(syms),stroff,len(strings))
    build=struct.pack('<6I',0x32,24,8,27<<16,27<<16,0)
    return header+seg+section1+section2+symtab+build+constbytes+textbytes+relocs+b''.join(syms)+strings

def make_ir(symbols, caller=False):
    out=f'target triple = "{TARGET}"\n%swift.async_func_pointer = type <{{ i32, i32 }}>\n'
    for i,(symbol,func,size) in enumerate(symbols):
        out+=f'@"{symbol}" = global %swift.async_func_pointer <{{ i32 trunc (i64 sub (i64 ptrtoint (ptr @"{func}" to i64), i64 ptrtoint (ptr @"{symbol}" to i64)) to i32), i32 {size} }}>, align 8\n'
        out+=f'define swifttailcc void @"{func}"(ptr swiftasync %0) {{\n'
        if caller:
            out+=f' %1 = load i32, ptr getelementptr inbounds (%swift.async_func_pointer, ptr @"{CONTROLS[i][0]}", i32 0, i32 1), align 8\n %2 = zext i32 %1 to i64\n %3 = call swiftcc ptr @swift_task_alloc(i64 %2)\n'
        out+=' ret void\n}\n'
    return out

def make_byte_caller(ir):
    # Exact observed Release spelling; all other optimized forms stay unknown.
    return (ir.replace('getelementptr inbounds (%swift.async_func_pointer,',
                       'getelementptr inbounds nuw (i8,')
              .replace('i32 0, i32 1)', 'i64 4)')
              .replace('call swiftcc ptr @swift_task_alloc(',
                       'tail call swiftcc ptr @swift_task_alloc('))

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def fake_output(args,**kw):
    if args[-1]=='--show-sdk-path': return SDK
    if args[-1]=='--show-sdk-version': return '27.0'
    raise AssertionError(args)

def fake_demangle(args,**kw):
    if args==['xcrun','swiftc','--version']:
        return SimpleNamespace(stdout=VERSION+'\n',stderr='swift-driver version: 1.168.6 \n')
    rows=[]
    for x in kw['input'].splitlines():
        name=x.removeprefix('_$s').removesuffix('Tu')
        module='AsyncLayoutControls' if name.startswith('control') else 'AsyncLayoutCaller'
        rows.append('async function pointer to '+module+'.'+name+'()')
    return SimpleNamespace(stdout='\n'.join(rows)+'\n')

def run_case(reader, addend, gep_flags="inbounds", caller_transform=None):
    with TemporaryDirectory(prefix='vplayer-control-review-') as tmp:
        tmp=Path(tmp); inp=tmp/'Synthetic.swift'
        inp.write_text('// Synthetic parser fixture, never compiled.\n')
        manifest={'schema':1,'compiler_version':VERSION,'driver_version':'swift-driver version: 1.168.6','target':TARGET,'sdk_path':SDK,'sdk_version':'27.0','configuration':'Debug','optimization':'-Onone','scope':'controls','pairs':[]}
        for role,syms in [('control',CONTROLS),('caller',CALLERS)]:
            ll=tmp/(role+'.ll'); obj=tmp/(role+'.o')
            ir=make_ir(syms,role=='caller').replace('getelementptr inbounds (', 'getelementptr '+gep_flags+' (')
            if role=='caller' and caller_transform: ir=caller_transform(ir)
            ll.write_text(ir); obj.write_bytes(make_object(syms,addend))
            common=['xcrun','swiftc','-target',TARGET,'-sdk',SDK,'-Onone',str(inp)]
            manifest['pairs'].append({'role':role,'ir':str(ll),'object':str(obj),'ir_sha256':sha(ll),'object_sha256':sha(obj),'ir_argv':common+['-emit-ir','-o',str(ll)],'object_argv':common+['-emit-object','-o',str(obj)],'inputs':{str(inp):sha(inp)}})
        path=tmp/'artifact-set.json'; path.write_text(json.dumps(manifest))
        output=io.StringIO()
        try:
            with patch.object(reader['subprocess'],'check_output',side_effect=fake_output),patch.object(reader['subprocess'],'run',side_effect=fake_demangle),contextlib.redirect_stdout(output):
                reader['artifact_mode'](path,VERSION)
        except RuntimeError as error:
            return False,str(error),output.getvalue()
        return True,'accepted',output.getvalue()

if __name__=='__main__':
    source=Path(sys.argv[1]).read_text()
    if sys.argv[1].endswith('.patch'):
        part=next(p for p in source.split('diff --git ')[1:] if p.startswith('a/Scripts/inspect-paused-async-contexts.py '))
        source='\n'.join(x[1:] for x in part.splitlines() if x.startswith('+') and not x.startswith('+++'))+'\n'
    reader={}; exec(compile(source,'unapplied_reader','exec'),reader)
    failures=[]
    for addend in (0,4,-4,2**31-1,-2**31):
        accepted,reason,output=run_case(reader,addend)
        print(f'SYNTHETIC addend={addend}: accepted={accepted}; reason={reason}; success_marker={"diagnostic_complete" in output}')
        if accepted != (addend==0) or (("diagnostic_complete" in output) != (addend==0)): failures.append(addend)
    # Observed native spelling: no-wrap constrains GEP arithmetic, while exact
    # descriptor, field, type and same-function SSA evidence remain mandatory.
    accepted,reason,output=run_case(reader,0,'inbounds nuw')
    if not accepted or 'diagnostic_complete' not in output: failures.append('inbounds nuw')
    print(f'SYNTHETIC inbounds nuw: accepted={accepted}; reason={reason}')
    caller=make_ir(CALLERS,True).replace('getelementptr inbounds (','getelementptr inbounds nuw (')
    symbol=CONTROLS[0][0]
    negatives={
        'unknown flag': caller.replace('inbounds nuw (','inbounds unknown ('),
        'reversed flags': caller.replace('inbounds nuw (','nuw inbounds ('),
        'duplicate flag': caller.replace('inbounds nuw (','inbounds nuw nuw ('),
        'missing inbounds': caller.replace('inbounds nuw (','nuw ('),
        'wrong descriptor': caller.replace(symbol,symbol+'Decoy'),
        'wrong GEP type': caller.replace('(%swift.async_func_pointer,','(i8,'),
        'wrong field': caller.replace('i32 0, i32 1)','i32 0, i32 0)'),
        'wrong load type': caller.replace('load i32,','load i64,'),
        'signed extension': caller.replace('zext i32','sext i32'),
        'unknown extension flag': caller.replace('zext i32','zext nneg i32'),
        'wrong loaded SSA': caller.replace('zext i32 %1','zext i32 %9'),
        'wrong allocator SSA': caller.replace('swift_task_alloc(i64 %2)','swift_task_alloc(i64 %9)'),
        'constant allocation': caller.replace('swift_task_alloc(i64 %2)','swift_task_alloc(i64 128)'),
        'cross-function chain': caller.replace(' %2 = zext',' ret void\n}\ndefine void @"decoy"() {\n %2 = zext'),
    }
    for name,ir in negatives.items():
        if reader['allocator_size_chain'](ir,symbol) is not None: failures.append(name)
    print(f'SYNTHETIC exact-chain rejection cases={len(negatives)}')
    # The exact packed <{ i32, i32 }> layout establishes field 1 at byte 4.
    # These are synthetic artifact/SSA checks, never native allocation evidence.
    for addend in (0,4,-4):
        accepted,reason,output=run_case(reader,addend,caller_transform=make_byte_caller)
        expected=addend==0
        if accepted!=expected or ('diagnostic_complete' in output)!=expected:
            failures.append(('byte GEP artifact',addend))
        print(f'SYNTHETIC byte GEP addend={addend}: accepted={accepted}; reason={reason}')
    byte_caller=make_byte_caller(make_ir(CALLERS,True))
    byte_negatives={
        'zero offset': byte_caller.replace('i64 4)', 'i64 0)'),
        'off-by-one offset': byte_caller.replace('i64 4)', 'i64 5)'),
        'next field offset': byte_caller.replace('i64 4)', 'i64 8)'),
        'negative offset': byte_caller.replace('i64 4)', 'i64 -4)'),
        'wrong offset width': byte_caller.replace('i64 4)', 'i32 4)'),
        'wrong GEP element type': byte_caller.replace('(i8, ptr', '(i32, ptr'),
        'wrong descriptor': byte_caller.replace(symbol, symbol+'Decoy'),
        'wrong load width': byte_caller.replace('load i32,', 'load i64,'),
        'signed extension': byte_caller.replace('zext i32', 'sext i32'),
        'unknown extension flag': byte_caller.replace('zext i32', 'zext nneg i32'),
        'wrong extension width': byte_caller.replace(' to i64', ' to i32'),
        'wrong loaded SSA': byte_caller.replace('zext i32 %1', 'zext i32 %9'),
        'wrong allocated SSA': byte_caller.replace('swift_task_alloc(i64 %2)', 'swift_task_alloc(i64 %9)'),
        'constant allocation': byte_caller.replace('swift_task_alloc(i64 %2)', 'swift_task_alloc(i64 128)'),
        'wrong allocator': byte_caller.replace('@swift_task_alloc(', '@other_alloc('),
        'unknown GEP flag': byte_caller.replace('inbounds nuw (', 'inbounds unknown ('),
        'reversed GEP flags': byte_caller.replace('inbounds nuw (', 'nuw inbounds ('),
        'missing inbounds': byte_caller.replace('inbounds nuw (', 'nuw ('),
        'unobserved missing nuw': byte_caller.replace('inbounds nuw (', 'inbounds ('),
        'cross-function chain': byte_caller.replace(' %2 = zext', ' ret void\n}\ndefine void @"decoy"() {\n %2 = zext'),
        'missing layout': byte_caller.replace('%swift.async_func_pointer = type <{ i32, i32 }>\n', ''),
        'different layout': byte_caller.replace('type <{ i32, i32 }>', 'type <{ i64, i32 }>'),
        'unpacked layout': byte_caller.replace('type <{ i32, i32 }>', 'type { i32, i32 }'),
    }
    for name,ir in byte_negatives.items():
        if reader['allocator_size_chain'](ir,symbol) is not None:
            failures.append(('byte GEP decoy',name))
    print(f'SYNTHETIC byte-GEP exact-chain rejection cases={len(byte_negatives)}')
    for layout in ('<{ i64, i32 }>', '{ i32, i32 }'):
        transform=lambda ir: make_byte_caller(ir).replace('type <{ i32, i32 }>', 'type '+layout)
        accepted,reason,output=run_case(reader,0,caller_transform=transform)
        if accepted or 'diagnostic_complete' in output: failures.append(('byte GEP layout',layout))
    if failures: print('SYNTHETIC failures: '+repr(failures))
    print('Synthetic temporary artifacts removed. No native compiler was used.')
    sys.exit(bool(failures))
