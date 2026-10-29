from pathlib import Path
import json,subprocess,sys
sys.path.insert(0,'tool/playback_network')
from proxy_boundaries import record_proxy_observation
r=Path('/private/tmp/yl-same-resource-retry');results={};test='YlDashResourceLoaderTests/testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest()'
for name in ['same-url-targeted','macos-final','ios-final']:
 if not (r/(name+'-result.json')).exists():continue
 out=r/(name+'-attachments')
 if not out.exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(r/(name+'.xcresult')),'--output-path',str(out),'--test-id',test],check=True,capture_output=True,text=True)
 manifest=json.loads((out/'manifest.json').read_text());entries=[v for g in manifest for v in g['attachments'] if v['suggestedHumanReadableName'].startswith('queued-cancellation-evidence')];assert len(entries)==1
 item=entries[0];d=json.loads((out/item['exportedFileName']).read_text());old=d['trace'];new=d['followupTrace']
 assert d['parsedServerPaths']==['/held','/cancelled'] and len(d['parsedServerTraceIDs'])==2
 assert old['resourceToken']==new['resourceToken'] and old['correlationID']!=new['correlationID']
 assert old['correlationID'] not in d['parsedServerTraceIDs'] and new['correlationID']==d['parsedServerTraceIDs'][-1]
 assert old['cancelCause']==2 and old['taskOutcome']==1 and new['taskOutcome']==0
 assert new['admission']>=old['taskComplete']
 # Local ordinals from observed server parse order, not server-issued IDs.
 # Only the original cancelled row is checked: the later ID never repairs it.
 servers=[dict(requestId=i+1,proxyTraceID=ident) for i,ident in enumerate(d['parsedServerTraceIDs'])]
 check={'errors':[]};record_proxy_observation(check,[old],servers,6)
 assert not check['proxyRequestObservation']['fullyCorrelated'] and check['errors']==['proxy request correlation incomplete']
 results[name]=dict(device=item['deviceName'],deviceID=item['deviceId'],attachment=item['exportedFileName'],
   cancelledLifetimeMs=(old['downstreamTerminal']-old['admission'])*1000,
   explicitSameURLAdmissionAfterCancellationMs=(new['admission']-old['downstreamTerminal'])*1000,
   sameResourceToken=True,distinctRequestCorrelationIDs=True,cancelledRequestStillUncorrelated=True,
   followupTaskOutcome=new['taskOutcome'],strictParserCheck=check,capabilityAccepted=False,
   interpretation='Owned loopback single-slot characterization; explicit caller request, not inferred AVPlayer retry. Observed parse ordinals are normalization only.')
(r/'reproduction-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for name,d in results.items():print(name,d['device'],'cancelledMs',d['cancelledLifetimeMs'],'followupDeltaMs',d['explicitSameURLAdmissionAfterCancellationMs'])
