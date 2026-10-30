from pathlib import Path
import hashlib,json,subprocess
r=Path('/private/tmp/yl-reset-retry-control');e=Path('docs/superpowers/reports/evidence');old=json.loads((e/'2026-10-29-loopback-error-source/history.json').read_text());rows=[]
for name in [x['group'] for x in old]+['2026-10-29-loopback-error-source']:
 p=e/name/'SHA256SUMS';assert p.read_bytes()==subprocess.check_output(['git','show','e4c93978:'+str(p)])
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert hashlib.sha256((p.parent/n).read_bytes()).hexdigest()==h
 rows.append(dict(group=name,manifestSha256=hashlib.sha256(p.read_bytes()).hexdigest(),files=len(p.read_text().splitlines())))
(r/'history.json').write_text(json.dumps(rows,indent=2)+'\n');print('history',len(rows),sum(x['files'] for x in rows))
