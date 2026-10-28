import subprocess,json,sys,hashlib,shutil
from pathlib import Path
r=Path('/private/tmp/yl-postcommit-failure');old=Path('/private/tmp/yl-public-transport');mode=sys.argv[1]
if mode=='snapshot':
 names=set(json.loads((old/'review-source-identity.json').read_text()))
 names.add('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsHeaderPolicy.swift')
 names.update(['packages/yl_player/example/integration_test/apple_dash_credential_failure_test.dart','packages/yl_player/example/integration_test/support/apple_strict_support.dart','packages/yl_player/example/test_driver/integration_test.dart'])
 data={}
 for name in sorted(names):
  p=Path(name);b=p.read_bytes();q=r/'source-final'/name;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(b);data[name]=hashlib.sha256(b).hexdigest()
 (r/'source-identity.json').write_text(json.dumps(data,indent=2)+'\n');sys.exit()
if mode=='build':cmd=json.loads((old/'review-build-command.json').read_text());name='final-ios-build'
else:
 cmd=json.loads((old/('review-'+mode+'-contracts-command.json')).read_text());name='final-'+mode+'-contracts';cmd[cmd.index('-resultBundlePath')+1]=str(r/(name+'.xcresult'))
(r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(name+'-result.json')).write_text(json.dumps({'exitCode':p.returncode})+'\n');print(name,p.returncode,flush=True)
if mode!='build':
 for kind in ['summary','tests']:
  out=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(name+'.xcresult'))],capture_output=True,text=True);(r/(name+'-'+kind+'.json')).write_text(out.stdout)
sys.exit(p.returncode)
