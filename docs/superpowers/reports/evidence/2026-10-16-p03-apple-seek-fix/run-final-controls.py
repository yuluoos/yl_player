import json,subprocess,sys
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player')
scratch=Path('/private/tmp/yl-p03-seek-fix-20261016')
app=scratch/'build-public/Build/Products/Debug/yl_player_example.app'
checks={}
for name,flag in [('public-verified',None),('framework-negative-verified','--negative-framework'),('identity-negative-verified','--negative-identity'),('public-repeat-verified',None)]:
 command=[sys.executable,'-B',str(root/'tool/media_matrix/run_bound_flutter_apple.py'),'--app',str(app),'--platform','macos','--out',str(scratch/name)]
 if flag:command.append(flag)
 with (scratch/(name+'.log')).open('w') as log:code=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT).returncode
 result=json.loads((scratch/name/'result.json').read_text())
 print(name,code,{k:v for k,v in result.items() if k!='measurements'},flush=True)
 assert result['artifactsUnchanged'] and result['statusRunMatches'],name
 if flag=='--negative-identity':
  assert code==1 and not result['scopeAcceptance'] and not result['runtimeIdentityVerified'] and result['supportedRows']==0,name
 elif flag=='--negative-framework':
  assert code==1 and not result['scopeAcceptance'] and not result['publicTestPassed'] and result['supportedRows']==6 and not result['errors'] and result['runtimeIdentityVerified'],name
 else:assert code==0 and result['scopeAcceptance'] and result['supportedRows']==6 and result['publicTestPassed'] and result['runtimeIdentityVerified'],name
 checks[name]={'code':code,**{k:v for k,v in result.items() if k!='measurements'}}
 (scratch/'final-controls-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
