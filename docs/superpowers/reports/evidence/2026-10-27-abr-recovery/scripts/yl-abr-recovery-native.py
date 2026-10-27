import sys,json,time
from pathlib import Path
root=Path(sys.argv[1]);sys.path.insert(0,str(root/'tool/playback_network'))
import abr_accesslog,prepare_fixture
from types import SimpleNamespace
out=Path('/private/tmp/yl-abr-recovery-20261027-native');out.mkdir(exist_ok=False)
# Explicit test-only duration intervention; production and the native probe binary are unchanged.
abr_accesslog.create=lambda path:prepare_fixture.create(path,duration_seconds=120)
while True:
 try:
  rows=json.loads(Path('/private/tmp/yl-abr-recovery-20261027-runs/results.json').read_text())
  if len(rows)==6:break
 except (OSError,ValueError):pass
 time.sleep(5)
profile=json.loads((root/'tool/playback_network/profiles.json').read_text())['profiles'][0]
profile['id']='recovery-headroom-diagnostic-v1'
profile['steps'][-1]['bytesPerSecond']=2000000
custom=out/'headroom-profile.json';custom.write_text(json.dumps({'schemaVersion':1,'profiles':[profile]},indent=2)+'\n')
results=[]
for name,profiles,profile_id in [('original',root/'tool/playback_network/profiles.json','down-and-recover-v1'),('headroom',custom,profile['id'])]:
 print('START native '+name,flush=True)
 result=abr_accesslog.run(SimpleNamespace(products=Path('/private/tmp/yl-remaining-20261026-ios/Build/Products'),directory=out/name,device='B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8',profiles=profiles,profile=profile_id))
 results.append({k:v for k,v in result.items() if k!='binaryHashes'})
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
 print('END native '+name+' '+json.dumps(results[-1]),flush=True)
