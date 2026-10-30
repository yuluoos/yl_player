from pathlib import Path
import json,subprocess,sys,hashlib
r=Path('/private/tmp/yl-final-media-budget');old=Path('/private/tmp/yl-timeout-overflow');results={}
sys.path.insert(0,'tool/playback_network');from transaction_metrics import summarize_transactions
for platform in ('ios','macos'):
 out=r/(platform+'-controlled-attachments');bundle=old/(platform+'-final.xcresult')
 if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose()'],check=True,capture_output=True)
 manifest=json.loads((out/'manifest.json').read_text());files=[v for group in manifest for v in group['attachments'] if v['suggestedHumanReadableName'].startswith('forced-close-transaction-bytes')];assert len(files)==1
 p=out/files[0]['exportedFileName'];d=json.loads(p.read_text());trace=d['trace'];m=summarize_transactions(trace['metrics'])
 assert d['forcedFirstConnectionClose'] and len(d['parsedServerTraceIDs'])==2 and len(set(d['parsedServerTraceIDs']))==1
 assert m['transactionCount']==2 and not m['complete'] and trace['taskOutcome']==0 and trace['outcome']==0
 assert m['transactions'][0]['transportBytes']['responseHeaders']==0 and m['transactions'][0]['transportBytes']['responseBody']==0
 results[platform]=dict(sourceBundle=str(bundle),sourceArtifact='docs/superpowers/reports/evidence/2026-10-29-native-timeout-overflow/'+platform+'-final.xcresult.tar.gz.part000',attachmentSha256=hashlib.sha256(p.read_bytes()).hexdigest(),trace=trace,parsedServerTraceIDs=d['parsedServerTraceIDs'],forcedFirstConnectionClose=True,newExecution=False,historicalCauseEstablished=False,metrics=m)
(r/'controlled-double-transactions.json').write_text(json.dumps(results,indent=2)+'\n')
for platform,x in results.items():print(platform,'parsed',len(x['parsedServerTraceIDs']),'bytes',[t['transportBytes'] for t in x['metrics']['transactions']])
