from pathlib import Path
import json,re
r=Path('/private/tmp/yl-reset-retry-control');result={}
for n in ['budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild']:
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 read=lambda name:[json.loads(x) for x in (p/name).read_text().splitlines() if x.strip()]
 ss=read('requests.jsonl');bs=read('proxy-requests.jsonl');by={b['correlationID'].lower():b for b in bs};items=[]
 for s in ss:
  if s['startMs'] is not None and (69000 if 'late-' in n else 59000)<=s['startMs']<(76000 if 'late-' in n else 66000) and re.search(r'/(?:init|chunk)-1(?:-|\.)',s['asset']):
   b=by[s['proxyTraceID'].lower()]
   items.append(dict(server={k:s[k] for k in ['requestId','asset','startMs','endMs','outcome','bodyBytesWritten','phaseBytesWritten','serverTiming']},proxy=b,downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,receivedLessThanServerWritten=b['bodyBytes']<s['bodyBytesWritten']))
 result[n]=dict(items=items,interpretation='Server writes are not peer receipt. Native callback times and server profile times are separate clocks; durations are reported separately. v7 cancelSource distinguishes the first recorded connection-state failure (1), header receive error (2), or admitted monitor receive error (3); the callback is not the underlying peer decision; no specific TCP flag, OS-internal cancellation decision or AVPlayer penalty timer is proven.',rootCauseEstablished=False)
(r/'high-request-boundaries.json').write_text(json.dumps(result,indent=2)+'\n')
print('high request boundaries', {k:len(v['items']) for k,v in result.items()})
