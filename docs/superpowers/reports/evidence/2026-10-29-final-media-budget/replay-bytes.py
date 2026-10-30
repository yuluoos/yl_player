from pathlib import Path
import json,hashlib,sys,subprocess
sys.path.insert(0,'tool/playback_network')
from transaction_metrics import summarize_transactions
from proxy_boundaries import record_proxy_observation
r=Path('/private/tmp/yl-final-media-budget');out=r/'byte-replay';out.mkdir(exist_ok=True);allrows={}
for base,names in [('/private/tmp/yl-same-resource-retry',['normal','normal-repeat','normal-third','original']),('/private/tmp/yl-transaction-bytes',['normal','original'])]:
 for name in names:
  p=Path(base)/'media'/name;label=Path(base).name+'/'+name
  before={v.name:hashlib.sha256(v.read_bytes()).hexdigest() for v in p.glob('*.json*')}
  old=json.loads((p/'receipt.json').read_text());rows=[json.loads(v) for v in (p/'proxy-requests.jsonl').read_text().splitlines() if v.strip()];servers=[json.loads(v) for v in (p/'requests.jsonl').read_text().splitlines() if v.strip()]
  receipt={'errors':[]};record_proxy_observation(receipt,rows,servers,6)
  baseline=json.loads(Path('/private/tmp/yl-transaction-bytes/legacy-replay/replay-results.json').read_text())[name]['errors'] if base.endswith('yl-same-resource-retry') else old['errors']
  assert receipt['errors']==[e for e in baseline if e.startswith('proxy ')]
  details=[]
  for row in rows:
   m=summarize_transactions(row.get('metrics'));matches=[s['requestId'] for s in servers if s.get('proxyTraceID','').lower()==row['correlationID'].lower()]
   if not matches or (row.get('metrics') or {}).get('transactionCount',0)>1:
    details.append(dict(proxyID=row['proxyID'],requestID=row['requestID'],cancelCause=row.get('cancelCause'),serverRequestIDs=matches,metrics=m,taskOutcome=row.get('taskOutcome')))
  assert before=={v.name:hashlib.sha256(v.read_bytes()).hexdigest() for v in p.glob('*.json*')}
  allrows[label]=dict(oldPassed=old['passed'],proxyErrors=receipt['errors'],details=details,originalRawHashes=before,capabilityAccepted=False)
(out/'results.json').write_text(json.dumps(allrows,indent=2)+'\n')
for name,d in allrows.items():print(name,d['oldPassed'],d['proxyErrors'],[(v['requestID'],v['serverRequestIDs'],v['metrics']['byteEvidence']) for v in d['details']])
