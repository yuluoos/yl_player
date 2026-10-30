from pathlib import Path
import json
r=Path('/private/tmp/yl-queued-cancel');results={}
def rows(p):return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
for batch,names in [('yl-cancel-settlement',['normal','normal-repeat']),('yl-queued-cancel',['normal','normal-repeat','original','original-repeat'])]:
 for name in names:
  p=Path('/private/tmp')/batch/'media'/name
  if not (p/'receipt.json').exists():continue
  traces=rows(p/'proxy-requests.jsonl');serverIDs={x.get('proxyTraceID') for x in rows(p/'requests.jsonl')};samples=rows(p/'rows.jsonl');found=[]
  for b in traces:
   if b['correlationID'] in serverIDs:continue
   same=[x for x in traces if x['proxyID']==b['proxyID']]
   active=[x for x in same if x['admission']<=b['admission']<x['taskComplete']]
   nearby=[x for x in same if abs(x['downstreamTerminal']-b['downstreamTerminal'])<=.1]
   before=[s for s in samples if s['sampleUptime']<=b['admission']];after=[s for s in samples if s['sampleUptime']>=b['downstreamTerminal']]
   found.append(dict(trace=b,activeAtAdmission=[dict(requestID=x['requestID'],admission=x['admission'],taskComplete=x['taskComplete']) for x in active],
    nearbyTerminalObservations=[dict(requestID=x['requestID'],cancelCause=x.get('cancelCause'),outcome=x['outcome'],offsetMs=(x['downstreamTerminal']-b['downstreamTerminal'])*1000) for x in nearby],
    sampleBefore=before[-1]['elapsed'] if before else None,sampleAfter=after[0]['elapsed'] if after else None,
    interpretation='Tracked task lifetimes, not Foundation connection occupancy. They cannot establish its internal scheduling or AVPlayer decision.'))
  results[batch+'/'+name]=found
(r/'failure-cause-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for name,found in results.items():
 for v in found:print(name,v['trace']['requestID'],'cause',v['trace'].get('cancelCause'),'activeAtAdmission',[t['requestID'] for t in v['activeAtAdmission']])
