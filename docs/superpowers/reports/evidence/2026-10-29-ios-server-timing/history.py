from pathlib import Path
import hashlib,json,subprocess
r=Path('/private/tmp/yl-server-timing');base=Path('docs/superpowers/reports/evidence');sha=lambda b:hashlib.sha256(b).hexdigest()
prior=json.loads((base/'2026-10-29-ios-transaction-metrics/prior-evidence.json').read_text())+[{'group':'2026-10-29-ios-transaction-metrics'},{'group':'2026-10-29-abr-main-merge'},{'group':'2026-10-29-ios-connection-persistence'}]
for row in prior:
 p=base/row['group']/'SHA256SUMS';original=subprocess.check_output(['git','show','35819ab9:'+str(p)]);assert p.read_bytes()==original
 lines=p.read_text().splitlines()
 for line in lines:
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h,(p,n)
 row.update(files=len(lines),manifestSha256=sha(p.read_bytes()))
(r/'prior-evidence.json').write_text(json.dumps(prior,indent=2)+'\n');print(len(prior),sum(i['files'] for i in prior))
