from pathlib import Path
import json,subprocess,time
out=Path('/private/tmp/yl-public-policy/checks');out.mkdir(exist_ok=True)
commands=json.loads(Path('docs/superpowers/reports/evidence/2026-10-28-ios-policy-intent/checks/results.json').read_text())
commands.insert(2,dict(name='consumer-fixtures',command=['python3','-B','-m','unittest','discover','-s','tool/consumer_fixtures/apple_flutter','-p','test_*.py','-v']))
results=[]
for r in commands:
 start=time.monotonic()
 with (out/(r['name']+'.log')).open('w') as f:p=subprocess.run(r['command'],stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=r['name'],command=r['command'],exitCode=p.returncode,seconds=time.monotonic()-start))
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(r['name'],p.returncode,flush=True)
