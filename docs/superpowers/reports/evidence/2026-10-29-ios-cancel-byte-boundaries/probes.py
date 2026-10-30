from pathlib import Path
import subprocess,json,sys
sys.path.insert(0,'tool/playback_network')
from transaction_metrics import summarize_transactions
r=Path('/private/tmp/yl-cancel-byte-boundaries');result={}
tests={'forced':('testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose','forced-close-transaction-bytes'),'queued':('testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest','queued-cancellation-evidence'),'unoccupied':('testUnoccupiedProxyCancellationPreservesTransportAndServerEvidence','unoccupied-cancellation-evidence')}
for run in sys.argv[1:]:
 kinds=['unoccupied'] if run.startswith('native-probe') else list(tests)
 for kind in kinds:
  test,prefix=tests[kind];out=r/(run+'-'+kind+'-attachments')
  if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(r/(run+'.xcresult')),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/'+test+'()'],check=True,capture_output=True,text=True)
  manifest=json.loads((out/'manifest.json').read_text());items=[v for g in manifest for v in g['attachments'] if v['suggestedHumanReadableName'].startswith(prefix)];assert len(items)==1;item=items[0];d=json.loads((out/item['exportedFileName']).read_text())
  samples=d['samples'] if kind=='unoccupied' else [d];rows=[]
  for sample in samples:
   trace=sample['trace'];metrics=summarize_transactions(trace['metrics']);serverIDs=sample['parsedServerTraceIDs']
   # Preserve multiplicity: several server requests can belong to one task.
   matches=[i for i,v in enumerate(serverIDs) if v.lower()==trace['correlationID'].lower()]
   row=dict(trace=trace,metrics=metrics,parsedServerTraceIDs=serverIDs,matchedServerParseIndices=matches,
     serverSnapshotAfterExplicitFollowup=sample.get('snapshotAfterExplicitFollowup',False),capabilityAccepted=False)
   if 'followupTrace' in sample:row['followupTrace']=sample['followupTrace']
   rows.append(row)
  result[run+'/'+kind]=dict(device=item['deviceName'],samples=rows,capabilityAccepted=False,
    interpretation='Controlled boundary observations; list indices are server parses for a task, not per-transaction correspondence. Empty or unknown byte evidence is not zero. No historical cause or acceptance inferred.')
  print(run,kind,[(v['trace']['metrics']['transactionCount'],len(v['matchedServerParseIndices']),v['metrics']['byteEvidence']['transactions']) for v in rows])
old=json.loads((r/'probe-analysis.json').read_text()) if (r/'probe-analysis.json').exists() else {};old.update(result);(r/'probe-analysis.json').write_text(json.dumps(old,indent=2)+'\n')
