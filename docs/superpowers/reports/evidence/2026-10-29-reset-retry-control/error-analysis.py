from pathlib import Path
import json,re,collections
r=Path('/private/tmp/yl-reset-retry-control');result={}
for name in ('budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild'):
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 read=lambda f:[json.loads(v) for v in (p/f).read_text().splitlines() if v.strip()]
 bs=read('proxy-requests.jsonl');ss=read('requests.jsonl');by={v.get('proxyTraceID','').lower():v for v in ss};errors=[]
 assert all(b['version']==7 for b in bs)
 for b in bs:
  if b['cancelCause']!=3:continue
  s=by.get(b['correlationID'].lower());assert b['cancelSource'] in (1,2,3)
  high=bool(s and re.search(r'/(?:init|chunk)-1(?:-|\.)',s['asset']))
  laterHigh=[x for x in ss if s and x['startMs'] is not None and x['startMs']>s['startMs'] and re.search(r'/(?:init|chunk)-1(?:-|\.)',x['asset'])]
  errors.append(dict(proxyID=b['proxyID'],requestID=b['requestID'],source=b['cancelSource'],domain=b['cancelErrorDomain'],code=b['cancelErrorCode'],high=high,
   serverRequestID=s['requestId'] if s else None,asset=s['asset'] if s else None,
   bodyBytes=b['bodyBytes'],sentBodyBytes=b['sentBodyBytes'],serverWritten=s['bodyBytesWritten'] if s else None,
   proxyLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,
   serverStartMs=s['startMs'] if s else None,serverDurationMs=s['endMs']-s['startMs'] if s else None,
   laterHighRequestCount=len(laterHigh),metrics=b['metrics']))
 result[name]=dict(total=len(bs),sources=dict(collections.Counter(str(b['cancelSource']) for b in bs)),errorTuples=dict(collections.Counter(f"{e['source']}/{e['domain']}/{e['code']}" for e in errors)),errors=errors,
  sourceNames={'0':'no recorded cancellation error','1':'NWConnection.state.failed','2':'request header receive error','3':'admitted request monitor receive error'},
  caveats='First trace termination only. It does not record all later callbacks or establish private AVPlayer retry/penalty decisions. Request header errors before admission have no request trace. Source 0 also includes send failures whose cause is separately recorded by outcome; it is not proof of an error-free exchange.',rootCauseEstablished=False)
(r/'error-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for n,d in result.items():print(n,d['sources'],d['errorTuples'],[(e['requestID'],e['high'],e['laterHighRequestCount']) for e in d['errors']])
