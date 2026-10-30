from pathlib import Path
import json,sys
sys.path.insert(0,'tool/playback_network')
from abr_accesslog import read_rows
from transaction_metrics import summarize_transactions
r=Path('/private/tmp/yl-triggered-downshift');out={}
for name in ['budget-zero','normal-zero','budget-zero-repeat']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 b=read_rows(p/'proxy-requests.jsonl');s=read_rows(p/'requests.jsonl');byid={v['requestId']:v for v in s};health=json.loads((p/'server-health.json').read_text())['samples']
 out[name]=dict(proxyCount=len(b),cancelled=sum(v['outcome']==1 for v in b),multiTransactions=[v for v in b if (v.get('metrics') or {}).get('transactionCount',0)>1],
  unmatched=[v for v in b if v.get('serverRequestID') not in byid],
  missingMetrics=sum(v.get('metrics') is None for v in b),incompleteSuccessful=sum(v['outcome']==0 and not summarize_transactions(v.get('metrics'))['complete'] for v in b),
  source54=[{k:v.get(k) for k in ['proxyID','requestID','serverRequestID','cancelCause','cancelSource','cancelErrorDomain','cancelErrorCode','resourceToken','admission','downstreamTerminal']} for v in b if v.get('cancelErrorDomain')==1 and v.get('cancelErrorCode')==54],
  health=dict(samples=len(health),last=health[-1] if health else None,maximumGap=max((y['listenerSeconds']-x['listenerSeconds'] for x,y in zip(health,health[1:])),default=None)),capabilityAccepted=False)
(r/'boundary-analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for name,d in out.items():
 print(name,'proxy',d['proxyCount'],'unmatched',len(d['unmatched']),'multi',len(d['multiTransactions']),'health',d['health'])
 for v in d['unmatched']:print('unmatched',v)
