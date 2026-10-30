from pathlib import Path
import json,sys,xml.etree.ElementTree as ET,gzip
sys.path.insert(0,'tool/playback_network');from rendition_retry import summarize_rendition_retries
r=Path('/private/tmp/yl-triggered-downshift');result={}
for n in ('budget-zero','normal-zero','budget-zero-repeat'):
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 read=lambda f:[json.loads(v) for v in (p/f).read_text().splitlines() if v.strip()]
 bs=read('proxy-requests.jsonl');ss=read('requests.jsonl');rows=read('rows.jsonl')
 root=ET.fromstring((p/'fixture/manifest.mpd').read_bytes());ns='{urn:mpeg:dash:schema:mpd:2011}'
 # Fixture asset IDs are verified from the actual rendition declarations.
 high_ids={v.get('id') for v in root.iter(ns+'Representation') if v.get('width')=='640'}
 high_assets={s['asset'] for s in ss if any('/chunk-'+i+'-' in s['asset'] or '/init-'+i+'.' in s['asset'] for i in high_ids)}
 assert len(high_assets)>10 and all(x.startswith('network-period-') for x in high_assets)
 try: result[n]=summarize_rendition_retries(bs,ss,high_assets)
 except ValueError as error:
  result[n]=dict(highResets=None,diagnosticUnavailableReason=str(error),rootCauseEstablished=False,capabilityAccepted=False)
 result[n]['secondPhaseHighFailuresScope']='Only server admissions at or after fault start; empty does not exclude already-in-flight failures. See fault-overlap.json.'
 result[n]['assetSetProvenance']='actual frozen MPD representation width640 and correlated fixture paths'
 result[n]['highRequestFailures']=[dict(proxyID=b['proxyID'],requestID=b['requestID'],outcome=b['outcome'],cancelSource=b['cancelSource'],errorDomain=b['cancelErrorDomain'],errorCode=b['cancelErrorCode']) for b in bs if b['outcome']!=0 and next((s for s in ss if s.get('proxyTraceID','').lower()==b['correlationID'].lower()),{}).get('asset') in high_assets]
 result[n]['secondPhaseHighFailures']=[dict(proxyID=b['proxyID'],requestID=b['requestID'],outcome=b['outcome'],cancelSource=b['cancelSource'],errorDomain=b['cancelErrorDomain'],errorCode=b['cancelErrorCode']) for b in bs if b['outcome']!=0 and any(s.get('proxyTraceID','').lower()==b['correlationID'].lower() and s['asset'] in high_assets and s['startMs'] is not None and s['startMs']>=json.loads((p/'fault-server.json').read_text())['trigger']['startSeconds']*1000 for s in ss)]
 events=rows[-1]['automaticEvents'];installs=[v for v in events if v['outcome']=='installed'];end=installs[-1]['elapsedAfter'] if installs else None
 tail=[v for v in rows if end is not None and v['elapsed']>end]
 result[n]['postLastInstallErrorCounts']=sorted(set(v['errorLogEventCount'] for v in tail))
 result[n]['postLastInstallWidths']=sorted(set(v['width'] for v in tail))
 result[n]['passed']=json.loads((p/'receipt.json').read_text())['passed']
(r/'retry-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for n,d in result.items():print(n,'second-phase failed high',d['secondPhaseHighFailures'],'post-install errors',d['postLastInstallErrorCounts'],'post-install widths',d['postLastInstallWidths'],'reset followups',[(x['requestID'],x['sameProxyLaterHighRequests'],len(x['otherProxyLaterHighRequests'])) for x in (d['highResets'] or [])], 'unavailable',d.get('diagnosticUnavailableReason'))
