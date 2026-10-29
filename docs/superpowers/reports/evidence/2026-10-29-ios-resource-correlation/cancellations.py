from pathlib import Path
import json,collections
r=Path('/private/tmp/yl-resource-correlation')
def rows(p):return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
results={}
for batch,names in [('yl-cancel-settlement',['normal','normal-repeat']),('yl-resource-correlation',['original','normal','original-repeat','normal-repeat'])]:
 for name in names:
  p=Path('/private/tmp')/batch/'media'/name
  if not (p/'receipt.json').exists():continue
  samples=rows(p/'rows.jsonl');boundaries=rows(p/'proxy-requests.jsonl');servers=rows(p/'requests.jsonl');traceIDs={v.get('proxyTraceID','').lower():v['requestId'] for v in servers};cancelled=[b for b in boundaries if b['outcome']==1];installs=[e for e in samples[-1]['automaticEvents'] if e['outcome']=='installed'];details=[]
  for b in cancelled:
   linked=traceIDs.get(b.get('correlationID','').lower());transactions=(b.get('metrics') or {}).get('transactions',[])
   before=[s for s in samples if s['sampleUptime']<=b['admission']];after=[s for s in samples if s['sampleUptime']>=b['downstreamTerminal']]
   # Brackets use sampled same-device uptime. elapsed is read slightly earlier
   # than sampleUptime, so report nearby samples, not exact event elapsed.
   bracket=dict(beforeElapsed=before[-1]['elapsed'] if before else None,afterElapsed=after[0]['elapsed'] if after else None)
   details.append(dict(proxyID=b['proxyID'],requestID=b['requestID'],correlationID=b['correlationID'],serverRequestID=linked,
     cancelCause=b.get('cancelCause'),taskOutcome=b['taskOutcome'],downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,
     nearbyPlaybackSamples=bracket,firstInstallElapsed=installs[0]['elapsed'] if installs else None,
     recordedBeforeFirstInstall=bool(installs and after and after[0]['elapsed']<installs[0]['elapsed']),
     bodyBytes=b['bodyBytes'],sendCount=b['sendCount'],transactions=transactions))
  results[batch+'/'+name]=dict(cancelCauseCounts=dict(collections.Counter(str(b.get('cancelCause','legacy-unavailable')) for b in cancelled)),
    cancellations=len(cancelled),uncorrelated=[v for v in details if v['serverRequestID'] is None],allCancellationDetails=details)
(r/'cancellation-analysis.json').write_text(json.dumps(dict(interpretation='cancelCause is first recorded trace.finish observation, not total order of concurrent external events. No requestStart date/server match does not prove no network bytes were sent. No correlation exemption.',results=results,capabilityAccepted=False),indent=2)+'\n')
for name,d in results.items():print(name,d['cancelCauseCounts'],'unlinked',[(v['requestID'],v['cancelCause'],v['nearbyPlaybackSamples']) for v in d['uncorrelated']])
