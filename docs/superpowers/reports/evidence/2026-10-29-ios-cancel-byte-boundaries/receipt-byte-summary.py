from pathlib import Path
import json,collections,sys
sys.path.insert(0,'tool/playback_network')
from transaction_metrics import summarize_transactions
r=Path('/private/tmp/yl-cancel-byte-boundaries');out={}
for n in ['normal','original']:
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 rows=[json.loads(v) for v in (p/'proxy-requests.jsonl').read_text().splitlines() if v.strip()]
 servers=[json.loads(v) for v in (p/'requests.jsonl').read_text().splitlines() if v.strip()]
 states=collections.Counter();requestStates=collections.Counter();responseStates=collections.Counter();details=[]
 for row in rows:
  metrics=summarize_transactions(row.get('metrics'));b=metrics['byteEvidence'];states[b['availability']]+=1
  for t in b['transactions']:requestStates[t['request']]+=1;responseStates[t['response']]+=1
  matches=[s['requestId'] for s in servers if s.get('proxyTraceID','').lower()==row['correlationID'].lower()]
  if not matches or (row.get('metrics') or {}).get('transactionCount',0)>1:
   details.append(dict(proxyID=row['proxyID'],requestID=row['requestID'],correlationID=row['correlationID'],cancelCause=row.get('cancelCause'),serverRequestIDs=matches,metrics=metrics,taskOutcome=row.get('taskOutcome')))
 out[n]=dict(availability=dict(states),requestByteStates=dict(requestStates),responseByteStates=dict(responseStates),details=details,capabilityAccepted=False)
(r/'receipt-byte-summary.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
