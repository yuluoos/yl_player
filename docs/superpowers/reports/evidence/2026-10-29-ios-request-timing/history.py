from pathlib import Path
import hashlib,json,subprocess
r=Path('/private/tmp/yl-request-timing');base=Path('docs/superpowers/reports/evidence');sha=lambda b:hashlib.sha256(b).hexdigest()
prior=json.loads((base/'2026-10-29-ios-original-bandwidth/prior-evidence.json').read_text())+[{'group':'2026-10-29-ios-original-bandwidth'}]
for row in prior:
 p=base/row['group']/'SHA256SUMS';original=subprocess.check_output(['git','show','91ecf8f9:'+str(p)]);assert p.read_bytes()==original
 lines=p.read_text().splitlines()
 for line in lines:
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h,(p,n)
 row.update(files=len(lines),manifestSha256=sha(p.read_bytes()))
(r/'prior-evidence.json').write_text(json.dumps(prior,indent=2)+'\n');print(len(prior),sum(i['files'] for i in prior))
