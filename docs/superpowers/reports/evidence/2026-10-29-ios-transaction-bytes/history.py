from pathlib import Path
import hashlib,json,subprocess
r=Path('/private/tmp/yl-transaction-bytes');base=Path('docs/superpowers/reports/evidence');sha=lambda b:hashlib.sha256(b).hexdigest()
prior=json.loads(Path('/private/tmp/yl-failure-observations/prior-evidence.json').read_text())+[dict(group='2026-10-29-ios-failure-observations')]
for row in prior:
 p=base/row['group']/'SHA256SUMS';assert p.read_bytes()==subprocess.check_output(['git','show','d5f437f4:'+str(p)])
 lines=p.read_text().splitlines()
 for line in lines:
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
 row.update(files=len(lines),manifestSha256=sha(p.read_bytes()))
(r/'prior-evidence.json').write_text(json.dumps(prior,indent=2)+'\n');print(len(prior),sum(i['files'] for i in prior))
