import subprocess,json
from pathlib import Path
r=Path('/private/tmp/yl-fast-cancel');checks=[('ledger',['python3','-B','tool/release_readiness/check.py'],0),('ledger-required',['python3','-B','tool/release_readiness/check.py','--require-ready'],1),('threshold',['python3','-B','tool/playback_benchmark/threshold_registry.py'],0),('threshold-required',['python3','-B','tool/playback_benchmark/threshold_registry.py','--require-ready'],1),('ledger-tests',['python3','-B','-m','unittest','discover','-s','tool/playback_benchmark','-p','test_release_readiness.py','-v'],0),('diff',['git','diff','--check'],0)]
rows=[]
for name,cmd,expected in checks:
 p=subprocess.run(cmd,capture_output=True,text=True)
 (r/(name+'.stdout')).write_text(p.stdout);(r/(name+'.stderr')).write_text(p.stderr)
 rows.append(dict(name=name,command=cmd,exitCode=p.returncode,expected=expected));print(name,p.returncode)
(r/'readiness-results.json').write_text(json.dumps(rows,indent=2)+'\n');assert all(x['exitCode']==x['expected'] for x in rows)
d=json.loads((r/'ledger.stdout').read_text());assert d['sourceMatches'] and not d['releaseReady']
