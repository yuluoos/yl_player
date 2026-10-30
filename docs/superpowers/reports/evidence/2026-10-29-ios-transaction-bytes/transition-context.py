from pathlib import Path
import json,xml.etree.ElementTree as ET
r=Path('/private/tmp/yl-transaction-bytes');results={}
def rows(p):return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
for name in ['normal','original']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 traces=rows(p/'proxy-requests.jsonl');servers=rows(p/'requests.jsonl');samples=rows(p/'rows.jsonl');byTrace={s.get('proxyTraceID','').lower():s for s in servers}
 # Labels below are fixture metadata only, not production data inference.
 ns={'m':'urn:mpeg:dash:schema:mpd:2011'};manifest=ET.parse(p/'fixture/manifest.mpd').getroot();representations={}
 for adaptation in manifest.findall('.//m:AdaptationSet',ns):
  for rep in adaptation.findall('m:Representation',ns):
   representations[rep.attrib['id']]=dict(kind=adaptation.attrib.get('contentType'),width=rep.attrib.get('width'),bandwidth=rep.attrib.get('bandwidth'))
 events=[]
 for b in traces:
  before=[s for s in samples if s['sampleUptime']<=b['admission']];after=[s for s in samples if s['sampleUptime']>=b['downstreamTerminal']]
  if not before or not after or not (8<=before[-1]['elapsed']<=18):continue
  matched=byTrace.get(b.get('correlationID','').lower());asset=matched.get('asset') if matched else None
  repID=None
  if asset:
   stem=Path(asset).stem;parts=stem.split('-')
   if len(parts)>=2 and parts[0] in ('init','chunk'):repID=parts[1]
  events.append(dict(requestID=b['requestID'],proxyID=b['proxyID'],resourceToken=b['resourceToken'],
    admission=b['admission'],downstreamTerminal=b['downstreamTerminal'],
    beforeElapsed=before[-1]['elapsed'],afterElapsed=after[0]['elapsed'],outcome=b['outcome'],cancelCause=b['cancelCause'],
    serverRequestID=matched['requestId'] if matched else None,asset=asset,fixtureRepresentation=representations.get(repID)))
 results[name]=dict(events=events,interpretation='Nearby playback sample bounds only; each asset label comes from that exact request correlation. Missing matches stay null; resource-token relationships live separately.')
(r/'transition-context.json').write_text(json.dumps(results,indent=2)+'\n')
