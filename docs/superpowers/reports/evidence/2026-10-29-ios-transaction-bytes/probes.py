from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-transaction-bytes');result={}
tests={'forced':'testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose','queued':'testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest'}
for run,kinds in [('native-green',['forced']),('ios-final',['forced','queued']),('macos-final',['forced','queued'])]:
 for kind in kinds:
  out=r/(run+'-'+kind+'-attachments')
  if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(r/(run+'.xcresult')),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/'+tests[kind]+'()'],check=True,capture_output=True,text=True)
  manifest=json.loads((out/'manifest.json').read_text());prefix='forced-close-transaction-bytes' if kind=='forced' else 'queued-cancellation-evidence';items=[v for g in manifest for v in g['attachments'] if v['suggestedHumanReadableName'].startswith(prefix)];assert len(items)==1;item=items[0];d=json.loads((out/item['exportedFileName']).read_text());t=d['trace'];m=t['metrics'];assert m['version']==3
  row=dict(device=item['deviceName'],trace=t,parsedServerTraceIDs=d['parsedServerTraceIDs'],capabilityAccepted=False)
  if kind=='forced':
   assert len(d['parsedServerTraceIDs'])==2 and all(v==t['correlationID'] for v in d['parsedServerTraceIDs']);assert m['transactionCount']==2 and m['transactions'][0]['responseSeconds'] is None and m['transactions'][1]['responseSeconds'] is not None
   row['interpretation']='Owned forced-close reproduction; same task correlation was parsed twice. Not a historical-root-cause proof or strict media acceptance.'
  else:
   assert t['correlationID'] not in d['parsedServerTraceIDs'];row['followupTrace']=d['followupTrace'];row['interpretation']='Owned single-slot queued cancellation followed by explicit caller request. No transaction byte counts available when the transaction array is empty; this is not measured zero.'
  result[run+'/'+kind]=row
(r/'probe-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for n,v in result.items():print(n,[(x['transportBytes'],x['durationStates']['responseSeconds']) for x in v['trace']['metrics']['transactions']])
