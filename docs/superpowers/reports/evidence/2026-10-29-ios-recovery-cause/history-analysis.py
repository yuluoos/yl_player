import json,hashlib
from pathlib import Path
r=Path('/private/tmp/yl-recovery-cause');p=Path('/private/tmp/yl-production-exercise/media/pause-prepared')
rows=[json.loads(l) for l in (p/'proxy-requests.jsonl').read_text().splitlines()];multi=[q for q in rows if (q.get('metrics') or {}).get('transactionCount',0)>1];assert len(multi)==1
proxy=multi[0];requests=[json.loads(l) for l in (p/'requests.jsonl').read_text().splitlines()];matched=[q for q in requests if q.get('proxyTraceID')==proxy['correlationID']];assert len(matched)==1
ids={q['connectionId'] for q in requests};missing=sorted(set(range(1,max(ids)+1))-ids)
d=dict(originalReceiptPassed=json.loads((p/'receipt.json').read_text())['passed'],proxy=proxy,server=matched[0],acceptedConnectionIdGaps=missing,
 originalLifecycleAvailable=(p/'connection-lifecycle.json').exists(),interpretation='A successful second transaction has one matched server GET. No gaps among logged accepted IDs cannot exclude admission rejection, peer/network closure or failure before HTTP parsing. Missing historical lifecycle evidence cannot be recreated. Controlled response-less close reproduces shape but does not establish historical cause.',historicalCauseProven=False)
(r/'historical-double-transaction.json').write_text(json.dumps(d,indent=2)+'\n')
old=Path('/private/tmp/yl-budget-metrics');groups=json.loads((old/'prior-evidence.json').read_text())+[dict(group='2026-10-29-ios-budget-metrics')]
import subprocess
for row in groups:
 path=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert path.read_bytes()==subprocess.check_output(['git','show','9efd8319:'+str(path)])
 for line in path.read_text().splitlines():
  h,n=line.split('  ',1);assert hashlib.sha256((path.parent/n).read_bytes()).hexdigest()==h
 row.update(files=len(path.read_text().splitlines()),manifestSha256=hashlib.sha256(path.read_bytes()).hexdigest())
(r/'prior-evidence.json').write_text(json.dumps(groups,indent=2)+'\n');print('history',len(groups),sum(q['files'] for q in groups))
