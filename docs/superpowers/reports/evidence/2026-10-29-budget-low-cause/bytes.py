from pathlib import Path
import json
r=Path('/private/tmp/yl-budget-low-cause');results={}
def rows(p):return [json.loads(v) for v in p.read_text().splitlines() if v.strip()]
for n in ['budget-stall','budget-throttle','normal']:
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 bs=rows(p/'proxy-requests.jsonl');ss=rows(p/'requests.jsonl');by={s.get('proxyTraceID','').lower():s for s in ss};details=[]
 for b in bs:
  m=b['metrics'];assert m is None or m['version']==3
  match=by.get(b['correlationID'].lower())
  if not match or (m and m['transactionCount']>1):
   details.append(dict(proxyID=b['proxyID'],requestID=b['requestID'],cancelCause=b['cancelCause'],outcome=b['outcome'],taskOutcome=b['taskOutcome'],downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,
     correlatedServerRequestID=match['requestId'] if match else None,metrics=m))
 results[n]=dict(proxyCount=len(bs),cancelled=sum(b['outcome']==1 for b in bs),sendFailed=sum(b['outcome']==2 for b in bs),
  missingMetrics=sum(b['metrics'] is None for b in bs),zeroTransactionMetrics=sum(b['metrics'] is not None and b['metrics']['transactionCount']==0 for b in bs),
  multiTransactions=sum(b['metrics'] is not None and b['metrics']['transactionCount']>1 for b in bs),
  unknownByteFields=sum(v is None for b in bs if b['metrics'] for t in b['metrics']['transactions'] for v in t['transportBytes'].values()),
  uncorrelated=sum(b['correlationID'].lower() not in by for b in bs),details=details,
  interpretation='Foundation-reported transaction counts, not packet capture. Empty transactions and unknown counts are not zero. Counts neither establish server parsing nor repair missing response dates.',capabilityAccepted=False)
(r/'byte-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for n,v in results.items():
 print(n,{k:v[k] for k in ['proxyCount','cancelled','multiTransactions','uncorrelated']})
 for d in v['details']:print(d['requestID'],d['cancelCause'],d['correlatedServerRequestID'],[(t['transportBytes'],t['durationStates']['fetchToRequestSeconds'],t['durationStates']['responseSeconds']) for t in (d['metrics'] or {}).get('transactions',[])])
