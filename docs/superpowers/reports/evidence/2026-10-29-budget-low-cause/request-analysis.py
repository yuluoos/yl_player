from pathlib import Path
import json,re,collections,xml.etree.ElementTree as ET
r=Path('/private/tmp/yl-budget-low-cause');results={}
def read(p):return [json.loads(x) for x in p.read_text().splitlines() if x.strip()]
for label,p in [('previous-budget',Path('/private/tmp/yl-final-media-budget/media/pause-resume'))]+[(n,r/'media'/n) for n in ['budget-stall','budget-throttle','normal']]:
 if not (p/'receipt.json').exists():continue
 rows=read(p/'rows.jsonl');ss=read(p/'requests.jsonl');frames=read(p/'frame-samples.jsonl');policy=read(p/'policy-decisions.jsonl');proxy=read(p/'proxy-requests.jsonl');receipt=json.loads((p/'receipt.json').read_text())
 root=ET.fromstring((p/'fixture/manifest.mpd').read_bytes());ns='{urn:mpeg:dash:schema:mpd:2011}';renditions={}
 for v in root.iter(ns+'Representation'):
  value={'width':int(v.get('width','0')),'mimeType':v.get('mimeType')}
  if v.get('id') in renditions:assert renditions[v.get('id')]==value
  renditions[v.get('id')]=value
 def kind(row):
  m=re.search(r'/(?:init|chunk)-(\d+)[.-]',row['asset'])
  if not m:return 'manifest'
  v=renditions[m[1]];return 'high' if v['width']==640 else ('low' if v['width']==320 else 'audio')
 phases=[]
 for low,high in [(0,60000),(60000,65000),(65000,90000),(90000,None)]:
  selected=[s for s in ss if s['startMs'] is not None and low<=s['startMs'] and (high is None or s['startMs']<high)]
  phases.append(dict(startMs=low,endMs=high,requestCounts=dict(collections.Counter(kind(s) for s in selected)),outcomes=dict(collections.Counter(s['outcome'] for s in selected)),highRequests=[{k:s[k] for k in ['requestId','asset','startMs','endMs','outcome']} for s in selected if kind(s)=='high']))
 expected={'acceptedMaximumBitrate':None,'acceptedMaximumWidth':None,'acceptedMaximumHeight':None,'fixedTrackId':None,'peak':0,'maximumWidth':0,'maximumHeight':0}
 assert all(all(v.get(k)==x for k,x in expected.items()) for v in rows)
 errors=[dict(elapsed=v['elapsed'],count=v['errorLogEventCount'],automaticAttempts=v['automaticAttempts']) for i,v in enumerate(rows) if i==0 or v['errorLogEventCount']!=rows[i-1]['errorLogEventCount']]
 high=[s for s in ss if kind(s)=='high'];tail=[f for f in frames if f['elapsed']>=90 and f['frames']>0]
 matched={s.get('proxyTraceID','').lower() for s in ss};assert all(v['correlationID'].lower() in matched for v in proxy)
 installs=[e for e in rows[-1]['automaticEvents'] if e['outcome']=='installed'];install=installs[-1]['elapsedAfter'] if installs else None
 published=[f for f in frames if f['frames']>0 and (install is None or f['elapsed']>install)]
 first_high=next((f for f in published if f['width']==640),None)
 first_low=next((f for f in published if first_high and f['elapsed']>first_high['elapsed'] and f['width']==320),None)
 regained=next((f for f in published if first_low and f['elapsed']>first_low['elapsed'] and f['width']==640),None)
 proof=dict(lastInstall=install,firstHigh=first_high['elapsed'] if first_high else None,firstLowAfterHigh=first_low['elapsed'] if first_low else None,highAfterLow=regained['elapsed'] if regained else None,postInstallErrorCountTransitions=[v for v in errors if install is not None and v['elapsed']>install])
 results[label]=dict(postInstallOutput=proof,renditions=renditions,serverClockPhases=phases,deviceClockErrorCountTransitions=errors,allSamplesUnconstrained=True,lastHighServerRequest=max((s['startMs'] for s in high),default=None),tail90Seconds=dict(publishedFrames=sum(f['frames'] for f in tail),widths=sorted(set(f['width'] for f in tail)),positions=[tail[0]['position'],tail[-1]['position']] if tail else [],generations=sorted(set(f['generation'] for f in tail))),finalWidth=rows[-1]['width'],finalPosition=rows[-1]['position'],completed=rows[-1]['completed'],attempts=rows[-1]['automaticAttempts'],installed=sum(e['outcome']=='installed' for e in rows[-1]['automaticEvents']),policyReasons=dict(collections.Counter(v['reason'] for v in policy)),strictPassed=receipt['passed'],allProxyRequestsCorrelated=True,clockNote='Server profile timestamps and device elapsed timestamps are separate clock domains; no direct subtraction or precise cross-clock onset claim.',rootCauseEstablished=False,capabilityAccepted=False)
(r/'request-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for n,d in results.items():print(n,'highRequestsAfter65',sum(x['requestCounts'].get('high',0) for x in d['serverClockPhases'][2:]),'lastHigh',d['lastHighServerRequest'],'tailWidths',d['tail90Seconds']['widths'],'strict',d['strictPassed'])
