from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-half-close');result={}
for run in ('ios-final','macos-final','ios-confirm','macos-confirm'):
 if not (r/(run+'-result.json')).exists():continue
 assert json.loads((r/(run+'-result.json')).read_text())['exitCode']==0
 out=r/(run+'-attachments')
 if not (out/'manifest.json').exists():subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(r/(run+'.xcresult')),'--output-path',str(out),'--test-id','YlDashResourceLoaderTests/testHalfClosedClientCanReceiveDirectResponseButProxyCancels()'],check=True,capture_output=True)
 m=json.loads((out/'manifest.json').read_text());items=[v for g in m for v in g['attachments'] if v['suggestedHumanReadableName'].startswith('half-close-direction-evidence')];assert len(items)==1
 d=json.loads((out/items[0]['exportedFileName']).read_text());result[run]=d
 print(run,d['observations'],[(v['cancelCause'],v['metrics']['transactionCount']) for v in d['traces']])
(r/'observations.json').write_text(json.dumps(result,indent=2)+'\n')
