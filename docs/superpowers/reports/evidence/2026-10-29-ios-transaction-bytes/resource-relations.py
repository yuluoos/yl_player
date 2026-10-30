from pathlib import Path
import json,collections
r=Path('/private/tmp/yl-transaction-bytes');results={}
def rows(p):return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
for name in ['normal','original']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 traces=rows(p/'proxy-requests.jsonl');servers=rows(p/'requests.jsonl');byTrace={s.get('proxyTraceID','').lower():s for s in servers};groups=collections.defaultdict(list)
 for b in traces:
  assert b['version']==6
  groups[(b['proxyID'],b['resourceToken'])].append(b)
 cancelled=[]
 for b in traces:
  if b['outcome']!=1:continue
  matched=byTrace.get(b.get('correlationID','').lower());related=[]
  for other in groups[(b['proxyID'],b['resourceToken'])]:
   if other['requestID']==b['requestID']:continue
   server=byTrace.get(other.get('correlationID','').lower())
   related.append(dict(requestID=other['requestID'],outcome=other['outcome'],cancelCause=other['cancelCause'],
      admissionRelativeToCancellationMs=(other['admission']-b['downstreamTerminal'])*1000,
      thisAdmissionAfterRelatedCancellationMs=(b['admission']-other['downstreamTerminal'])*1000,
      thisAdmissionAfterRelatedTaskCompletionMs=(b['admission']-other['taskComplete'])*1000,
      strictlyAfterCancellation=other['admission']>=b['downstreamTerminal'],
      serverRequestID=server['requestId'] if server else None,asset=server.get('asset') if server else None,
      serverOutcome=server.get('outcome') if server else None,
      rangeStart=server.get('rangeStart') if server else None,rangeEndExclusive=server.get('rangeEndExclusive') if server else None))
  later=[v for v in related if v['strictlyAfterCancellation'] and v['outcome']==0 and v['serverOutcome']=='complete']
  cancelled.append(dict(proxyID=b['proxyID'],requestID=b['requestID'],resourceToken=b['resourceToken'],cancelCause=b['cancelCause'],
    serverRequestID=matched['requestId'] if matched else None,serverAsset=matched.get('asset') if matched else None,
    admission=b['admission'],downstreamTerminal=b['downstreamTerminal'],downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,
    relatedRequests=related,laterCompletedSameURLRequests=later,
    relatedServerAssetCandidates=sorted({v['asset'] for v in related if v['asset']}),
    requestCorrelationEstablished=matched is not None))
 results[name]=dict(totalRequests=len(traces),distinctProxyResources=len(groups),
   cancellations=cancelled,uncorrelated=[v for v in cancelled if not v['requestCorrelationEstablished']],
   interpretation='Resource token compares exact original URL only within one proxy. Related requests do not establish this request reached server, identical range/method/credentials/content, or why AVPlayer closed it.',
   capabilityAccepted=False,physicalOutputVerified=False)
(r/'resource-relations.json').write_text(json.dumps(results,indent=2)+'\n')
for name,d in results.items():
 print(name,'uncorrelated',[(b['requestID'],b['relatedServerAssetCandidates'],[(v['requestID'],round(v['admissionRelativeToCancellationMs'],3)) for v in b['laterCompletedSameURLRequests']]) for b in d['uncorrelated']])
