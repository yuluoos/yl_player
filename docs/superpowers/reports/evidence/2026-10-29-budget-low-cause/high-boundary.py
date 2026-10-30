from pathlib import Path
import json,re
r=Path('/private/tmp/yl-budget-low-cause');result={}
for n in ['budget-stall','budget-throttle','normal']:
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 read=lambda name:[json.loads(x) for x in (p/name).read_text().splitlines() if x.strip()]
 ss=read('requests.jsonl');bs=read('proxy-requests.jsonl');by={b['correlationID'].lower():b for b in bs};items=[]
 for s in ss:
  if s['startMs'] is not None and 59000<=s['startMs']<66000 and re.search(r'/(?:init|chunk)-1(?:-|\.)',s['asset']):
   b=by[s['proxyTraceID'].lower()]
   items.append(dict(server={k:s[k] for k in ['requestId','asset','startMs','endMs','outcome','bodyBytesWritten','phaseBytesWritten','serverTiming']},proxy=b,downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,receivedLessThanServerWritten=b['bodyBytes']<s['bodyBytesWritten']))
 result[n]=dict(items=items,interpretation='Server writes are not peer receipt. Native callback times and server profile times are separate clocks; durations are reported separately. cancelCause 3 is shared by loopback connection failure and receive-error callbacks; this trace cannot distinguish the specific callback; no specific TCP flag, OS-internal cancellation decision or AVPlayer penalty timer is proven.',rootCauseEstablished=False)
(r/'high-request-boundaries.json').write_text(json.dumps(result,indent=2)+'\n')
print('high request boundaries', {k:len(v['items']) for k,v in result.items()})
