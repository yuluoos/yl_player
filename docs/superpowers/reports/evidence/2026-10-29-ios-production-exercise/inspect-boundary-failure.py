import sys,json,traceback
from pathlib import Path
sys.path.insert(0,'tool/playback_network');from proxy_boundaries import summarize_proxy_boundaries
r=Path('/private/tmp/yl-production-exercise');p=r/'media/pause-prepared';rows=[json.loads(x) for x in (p/'proxy-requests.jsonl').read_text().splitlines()];servers=[json.loads(x) for x in (p/'requests.jsonl').read_text().splitlines()];findings=[]
def trace(frame,event,arg):
 if event=='exception' and frame.f_code.co_name=='summarize_proxy_boundaries':
  findings.append(dict(line=frame.f_lineno,error=str(arg[1]),row=frame.f_locals.get('row'),server=frame.f_locals.get('server'),transaction_metrics=frame.f_locals.get('transaction_metrics')))
 return trace
sys.settrace(trace)
try:summarize_proxy_boundaries(rows,servers,2)
except ValueError:pass
finally:sys.settrace(None)
(r/'boundary-failure.json').write_text(json.dumps(findings,indent=2)+'\n')
for f in findings:
 q=f['row'];print('line',f['line'],'outcome',q['outcome'],'id',q['requestID'],'metrics',q.get('metrics'),'timing',{k:q.get(k) for k in ['admission','terminal','response','firstBody','lastBody','upstreamComplete','firstSend','lastSend','lastSendComplete']})
