import base64,gzip,json,subprocess,sys
from pathlib import Path
root=Path.cwd(); sys.path.insert(0,str(root/'tool/media_matrix'))
from bound_artifacts import sha_file,verify
from bound_matrix import summarize
platform=sys.argv[1]
base=Path('/private/tmp/yl-remaining-device-20261105')
initial=base/('ios-matrix' if platform=='ios' else 'android-final-matrix')
original=base/sys.argv[2] if len(sys.argv)>2 else initial
output=base/sys.argv[3] if len(sys.argv)>3 else base/(platform+'-rechecks');output.mkdir(exist_ok=False)
matrix=json.loads((original/'matrix-plan.json').read_text())
records=json.loads(gzip.decompress((original/'records.json.gz').read_bytes()))
product=json.loads((initial/'product-files.json').read_text())
app=root/'packages/yl_player/example/build/remaining-device-ios/Build/Products/Debug-iphoneos/Runner.app'
apk=root/'packages/yl_player/example/build/app/outputs/flutter-apk/app-debug.apk'
def stable(): return verify(app,product) if platform=='ios' else sha_file(apk)==matrix['buildSha256']
assert stable()
selected={'ios':[('mov-hevc-aac','http'),('mkv-av1-opus','file')],
 'android':[('ts-avc-ac3','http'),('avi-avc-mp3','file'),('avi-avc-mp3','http'),('mkv-avc-flac','http'),('mkv-avc-ac3-51','file'),('mkv-avc-ac3-51','http')]}[platform]
if len(sys.argv)>4:selected=json.loads(sys.argv[4])
selection=[]
for case,transport in selected:
 index=next(i for i,r in enumerate(records) if r['cell']['caseId']==case and r['cell']['transport']==transport)
 old=records[index];folder=output/(case+'-'+transport)
 command=[sys.executable,'-B',str(root/'tool/media_matrix'/('run_bound_flutter_apple.py' if platform=='ios' else 'run_bound_flutter_android.py')),'--case',case,'--transport',transport,'--matrix-id',matrix['matrixId'],'--out',str(folder)]
 if platform=='ios':command+=['--platform','ios','--app',str(app),'--device','00008140-000C49CC3493001C','--flutter',str(base/'flutter/bin/flutter')]
 else:command+=['--apk',str(apk),'--serial','emulator-5580']
 with (output/(folder.name+'.log')).open('w') as log: result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=600 if platform=='ios' else 240)
 record=dict(cell=old['cell'],plan={},rows=[],status={},artifactsUnchanged=False,exitCode=result.returncode)
 try:
  for key in ['plan','status']:record[key]=json.loads((folder/(key+'.json')).read_text())
  record['rows']=json.loads(gzip.decompress((folder/'rows.json.gz').read_bytes()))
  if platform=='android':
   record['extractedJsonlBase64']=base64.b64encode(gzip.decompress((folder/'extracted.jsonl.gz').read_bytes())).decode()
   record['extractExit']=json.loads((folder/'extraction.json').read_text())['exitCode']
  record['artifactsUnchanged']=stable()
 except Exception as error:record['collectorError']=str(error)
 records[index]=record
 selection.append(dict(caseId=case,transport=transport,originalRunId=old['plan'].get('runId'),originalExit=old.get('exitCode'),selectedRunId=record['plan'].get('runId'),selectedExit=result.returncode,command=command))
 print(case,transport,'exit',result.returncode,flush=True)
 (output/'attempt-selection.json').write_text(json.dumps(selection,indent=2)+'\n')
matrix['artifactFinalVerified']=stable()
(output/'matrix-plan.json').write_text(json.dumps(matrix,indent=2)+'\n')
with gzip.open(output/'records.json.gz','wb') as f:f.write(json.dumps(records,sort_keys=True).encode())
result=summarize(matrix,records)
(output/'matrix-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['rows','missing']},indent=2),flush=True)
