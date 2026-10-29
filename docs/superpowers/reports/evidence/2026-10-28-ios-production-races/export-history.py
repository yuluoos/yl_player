from pathlib import Path
import json,subprocess,hashlib
raw=Path('/private/tmp/yl-production-races');sha=lambda b:hashlib.sha256(b).hexdigest()
for path in sorted(raw.rglob('*.xcresult')):
 for kind in ['summary','tests']:
  dest=path.with_name(path.stem+'-'+kind+'.json')
  if dest.exists() and dest.stat().st_size:continue
  result=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(path)],capture_output=True,text=True)
  if result.returncode:print('export failure',path.name,kind,result.returncode);continue
  dest.write_text(result.stdout)
base=Path('docs/superpowers/reports/evidence')
prior=json.loads((base/'2026-10-28-ios-production-recovery/prior-evidence.json').read_text())
prior.append(dict(group='2026-10-28-ios-production-recovery'))
for row in prior:
 p=base/row['group']/'SHA256SUMS';h=sha(p.read_bytes())
 if 'manifestSha256' in row:assert h==row['manifestSha256']
 lines=p.read_text().splitlines()
 for line in lines:
  expected,name=line.split('  ',1);assert sha((p.parent/name).read_bytes())==expected,(row['group'],name)
 row.update(files=len(lines),manifestSha256=h)
(raw/'prior-evidence.json').write_text(json.dumps(prior,indent=2)+'\n');print('prior groups',len(prior),'files',sum(r['files'] for r in prior))
