from pathlib import Path
import subprocess,json
out=Path('/private/tmp/yl-public-race/readiness');out.mkdir(exist_ok=True)
commands=json.loads(Path('docs/superpowers/reports/evidence/2026-10-28-ios-policy-intent/readiness/results.json').read_text());results=[]
for r in commands:
 p=subprocess.run(r['command'],capture_output=True,text=True)
 for ext,value in [('stdout',p.stdout),('stderr',p.stderr)]: (out/(r['name']+'.'+ext)).write_text(value)
 results.append(dict(name=r['name'],command=r['command'],exitCode=p.returncode));assert p.returncode==r['exitCode'],r['name']
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
d=json.loads((out/'ledger-final.stdout').read_text());assert d['sourceMatches'] and not d['releaseReady'];print({k:d[k] for k in ['currentSourceHash','sourceMatches','releaseReady','rowCount','implementationCounts','verificationCounts']})
