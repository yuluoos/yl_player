from pathlib import Path
import json,subprocess,sys
sys.path.insert(0,'tool/playback_network')
from proxy_boundaries import record_proxy_observation
r=Path('/private/tmp/yl-queued-cancel');results={};test='YlDashResourceLoaderTests/testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest()'
for name in ['queued-first','queued-fast','macos-final','ios-final']:
 bundle=r/(name+'.xcresult');out=r/(name+'-attachments')
 if not (r/(name+'-result.json')).exists():continue
 if not out.exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(out),'--test-id',test],check=True,capture_output=True,text=True)
 manifest=json.loads((out/'manifest.json').read_text());entries=[item for group in manifest for item in group['attachments'] if item['suggestedHumanReadableName'].startswith('queued-cancellation-evidence')];assert len(entries)==1
 item=entries[0];d=json.loads((out/item['exportedFileName']).read_text());b=d['trace'];assert d['parsedServerPaths']==['/held','/after'] and b['correlationID'] not in d['parsedServerTraceIDs']
 assert b['outcome']==1 and b['cancelCause']==2 and b['taskOutcome']==1 and b['bodyBytes']==b['sendCount']==0
 # Normalize observed parsed-request order into local ordinal IDs for a parser
 # contract check only. These are NOT server-issued IDs or a media receipt.
 servers=[dict(requestId=i+1,proxyTraceID=ident) for i,ident in enumerate(d['parsedServerTraceIDs'])]
 check={'errors':[]};record_proxy_observation(check,[b],servers,5)
 assert not check['proxyRequestObservation']['fullyCorrelated'] and check['errors']==['proxy request correlation incomplete']
 summary=json.loads((r/(name+'-summary.json')).read_text());assert summary['failedTests']==0
 results[name]=dict(attachment=item['exportedFileName'],device=item['deviceName'],deviceID=item['deviceId'],
  downstreamLifetimeMs=(b['downstreamTerminal']-b['admission'])*1000,
  taskSettlementAfterCloseMs=(b['taskComplete']-b['downstreamTerminal'])*1000,
  cancelCause=b['cancelCause'],taskOutcome=b['taskOutcome'],transactionCount=b['metrics']['transactionCount'],
  transactions=b['metrics']['transactions'],requestCorrelationAbsent=True,parsedServerPaths=d['parsedServerPaths'],
  strictParserCheck=check,interpretation='Controlled real HTTP/1.1 single-connection queue, not AVPlayer historical root cause or physical media acceptance.',capabilityAccepted=False)
(r/'reproduction-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for name,d in results.items():print(name,d['device'],'lifetimeMs',d['downstreamLifetimeMs'],'transactionCount',d['transactionCount'],'strictlyUncorrelated',d['requestCorrelationAbsent'])
