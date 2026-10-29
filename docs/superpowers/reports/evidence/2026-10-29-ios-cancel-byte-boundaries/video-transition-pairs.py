from pathlib import Path
import json
r=Path('/private/tmp/yl-cancel-byte-boundaries');data=json.loads((r/'transition-context.json').read_text());pairs={}
for name,d in data.items():
 result=[]
 for e in d['events']:
  rep=e['fixtureRepresentation'] or {}
  if e['outcome']!=1 or rep.get('kind')!='video' or rep.get('width')!='640':continue
  later=[v for v in d['events'] if v['proxyID']==e['proxyID'] and v['admission']>=e['downstreamTerminal'] and (v['fixtureRepresentation'] or {}).get('width')=='320']
  if not later:continue
  v=min(later,key=lambda v:v['admission']);result.append(dict(cancelledRequest=e['requestID'],cancelledAsset=e['asset'],cancelCause=e['cancelCause'],nextLowerRequest=v['requestID'],nextLowerAsset=v['asset'],gapMs=(v['admission']-e['downstreamTerminal'])*1000))
 pairs[name]=result
(r/'video-transition-pairs.json').write_text(json.dumps(dict(results=pairs,interpretation='Same-proxy observed ordering of exactly correlated fixture video requests. Temporal proximity does not prove AVPlayer internal causality or establish unlinked requests.'),indent=2)+'\n')
