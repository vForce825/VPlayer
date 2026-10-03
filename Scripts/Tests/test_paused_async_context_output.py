"""Independent synthetic output-budget review; no native compilation or repo writes.
Usage: python3 -B Scripts/Tests/test_paused_async_context_output.py runner.sh-or-unapplied.patch
"""
from pathlib import Path
from tempfile import TemporaryDirectory
import json, subprocess, sys

source=Path(sys.argv[1]).read_text()
if sys.argv[1].endswith('.patch'):
    part=next(s for s in source.split('diff --git ')[1:] if s.startswith('a/Scripts/run-paused-async-context-controls.sh '))
    source='\n'.join(x[1:] for x in part.splitlines() if x.startswith('+') and not x.startswith('+++'))+'\n'
code=source.split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
limit=128*1024
failures=[]
with TemporaryDirectory(prefix='vplayer-control-log-review-') as tmp:
    tmp=Path(tmp); log=tmp/'gate.log'; ir=tmp/'Synthetic.ll'
    cases=[('healthy',b'compiler output\n','passed','',0,'passed'),
           ('oversized_success',b'x'*(limit+1),'passed','',1,'failed'),
           ('failure_plus_excerpt',b'x'*limit,'failed','\n'.join('%swift.async_func_pointer '+'x'*1100 for _ in range(32))+'\n',1,'failed'),
           ('unicode_failure',b'x'*(limit-32768),'failed','\n'.join('%swift.async_func_pointer '+'\U0001f9ea'*1100 for _ in range(32))+'\n',1,'failed')]
    for name,raw,result,irtext,expected_exit,expected_result in cases:
        log.write_bytes(raw); ir.write_text(irtext)
        run=subprocess.run([sys.executable,'-',str(log),'Debug',result,str(tmp)],input=code,text=True,capture_output=True)
        report=json.loads(run.stdout.splitlines()[0]); size=len(run.stdout.encode('utf-8'))
        good=run.returncode==expected_exit and report['result']==expected_result and size<=limit
        print(f'{name}: exit={run.returncode}; reported={report["result"]}; bytes={size}; PASS={good}')
        if not good: failures.append(name)
print('Synthetic temporary files removed.')
sys.exit(bool(failures))
