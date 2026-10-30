from pathlib import Path
import json,subprocess
r=Path('/private/tmp/yl-half-close-fix');results={}
for platform in ('ios','macos'):
 run=platform+'-fixed'
 if not (r/(run+'-result.json')).exists():continue
 assert json.loads((r/(run+'-result.json')).read_text())['exitCode']==0
 for name,test,prefix in [('response','testHalfClosedClientReceivesCompleteDirectAndProxyResponses','half-close-direction-evidence'),('deadline','testProxyDeadlineReclaimsSilentClosedAndNonReadingClients','bounded-connection-reclamation')]:
  out=r/(run+'-'+name+'-attachments')
  if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(r/(run+'.xcresult')),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/'+test+'()'],check=True,capture_output=True)
  m=json.loads((out/'manifest.json').read_text());f=[v for g in m for v in g['attachments'] if v['suggestedHumanReadableName'].startswith(prefix)];assert len(f)==1;d=json.loads((out/f[0]['exportedFileName']).read_text())
  if name=='response':
   assert all(v['receivedExpectedBody'] and not v['receiveFailed'] for v in d['observations'])
   assert d['traces'][0]['outcome']==0 and d['traces'][0]['taskOutcome']==0 and d['traces'][0]['cancelCause']==0
  else:
   assert {v['mode'] for v in d['samples']}==set(range(4))
   for v in d['samples']:
    assert v['elapsed']<2.5
    assert all(v['snapshot'][k]==0 for k in ['activeConnections','activeTasks','connectionDeadlines','activeRequestTraces'])
   v=next(v for v in d['samples'] if v['mode']==3);t=v['traces'][0]
   assert t['cancelCause']==4 and t['outcome']==1 and t['sendCount']>t['sendCompletions'] and t['bodyBytes']>t['sentBodyBytes'], 'nonreader must exercise blocked send + deadline'
  results[platform+'/'+name]=d;print(platform,name,'validated')
(r/'probe-validation.json').write_text(json.dumps(results,indent=2)+'\n')
