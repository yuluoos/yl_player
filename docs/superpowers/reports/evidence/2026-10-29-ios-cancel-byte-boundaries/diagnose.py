from pathlib import Path
import sys,json,traceback
sys.path.insert(0,'tool/playback_network')
from proxy_boundaries import summarize_proxy_boundaries
r=Path('/private/tmp/yl-cancel-byte-boundaries');out={}
def rows(p):return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
for n in ['normal','original']:
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 b=rows(p/'proxy-requests.jsonl');s=rows(p/'requests.jsonl');bad=[];multi=[]
 for t in b:
  matched=[v for v in s if v.get('proxyTraceID','').lower()==t.get('correlationID','').lower()]
  try:summarize_proxy_boundaries([t],s,6)
  except Exception as e:bad.append(dict(trace=t,error=str(e),traceback=traceback.format_exc(),matchedServerRows=matched))
  if (t.get('metrics') or {}).get('transactionCount',0)>1:multi.append(dict(trace=t,matchedServerRows=matched))
 out[n]=dict(invalidIndividualBoundaries=bad,multipleTransactions=multi,interpretation='Single-row validation locates violated conditions without altering full-run receipt or correlation gates. One parsed correlation ID does not map individual URLSession transactions or explain a missing response interval.',capabilityAccepted=False)
(r/'boundary-diagnosis.json').write_text(json.dumps(out,indent=2)+'\n')
print({n:dict(invalid=len(v['invalidIndividualBoundaries']),multi=len(v['multipleTransactions'])) for n,v in out.items()})
