from pathlib import Path
import json,sys
sys.path.insert(0,'tool/playback_network');from abr_accesslog import read_rows
r=Path('/private/tmp/yl-triggered-downshift');out={}
for n in ['budget-zero','normal-zero','budget-zero-repeat']:
 p=r/'media'/n;requests={v['requestId']:v for v in read_rows(p/'requests.jsonl')};trace=read_rows(p/'proxy-requests.jsonl');fault=json.loads((p/'fault-server.json').read_text())['trigger'];start=fault['startSeconds']*1000;end=fault['endSeconds']*1000
 found=[]
 for b in trace:
  s=requests.get(b.get('serverRequestID'))
  if not s or not isinstance(s.get('asset'),str) or '/chunk-1-' not in s['asset'] or b['outcome']==0:continue
  if s['startMs']<=end and s['endMs']>=start:
   found.append(dict(proxyID=b['proxyID'],requestID=b['requestID'],serverRequestID=b['serverRequestID'],asset=s['asset'],serverStartMs=s['startMs'],serverEndMs=s['endMs'],serverOutcome=s['outcome'],outcome=b['outcome'],cancelCause=b['cancelCause'],cancelSource=b['cancelSource'],domain=b['cancelErrorDomain'],code=b['cancelErrorCode'],bodyBytes=b['bodyBytes'],sentBodyBytes=b['sentBodyBytes']))
 out[n]=dict(faultStartMs=start,faultEndMs=end,overlappingHighFailures=found,causalityProven=False,capabilityAccepted=False)
 print(n,found)
(r/'fault-overlap.json').write_text(json.dumps(out,indent=2)+'\n')
