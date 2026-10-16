import json,subprocess,sys
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player')
scratch=Path('/private/tmp/yl-p03-seek-fix-20261016')
app=scratch/'build-public/Build/Products/Debug/yl_player_example.app'
sys.path.insert(0,str(root/'tool/media_matrix'))
from bound_artifacts import verify
checks={};builds=set()
for name,flag in [('consumption-public-final',None),('consumption-framework-negative','--negative-framework'),('consumption-identity-negative','--negative-identity'),('consumption-public-repeat',None)]:
 command=[sys.executable,'-B',str(root/'tool/media_matrix/run_bound_flutter_apple.py'),'--app',str(app),'--platform','macos','--out',str(scratch/name)]
 if flag:command.append(flag)
 with (scratch/(name+'.log')).open('w') as log:code=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT).returncode
 result=json.loads((scratch/name/'result.json').read_text())
 print(name,code,{k:v for k,v in result.items() if k!='measurements'},flush=True)
 product=json.loads((scratch/name/'product-files.json').read_text())
 assert verify(app,product) and result['statusRunMatches'],name
 builds.add(product['sha256'])
 if flag!='--negative-identity':assert result['artifactsUnchanged'],name
 if flag=='--negative-identity':
  assert code==1 and not result['scopeAcceptance'] and not result['runtimeIdentityVerified'] and result['supportedRows']==0,name
 elif flag=='--negative-framework':
  assert code==1 and not result['scopeAcceptance'] and not result['publicTestPassed'] and result['supportedRows']==6 and not result['errors'] and result['runtimeIdentityVerified'],name
 else:assert code==0 and result['scopeAcceptance'] and result['supportedRows']==6 and result['publicTestPassed'] and result['runtimeIdentityVerified'],name
 checks[name]={'code':code,**{k:v for k,v in result.items() if k!='measurements'}}
 (scratch/'consumption-controls-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
assert len(builds)==1 and len(checks)==4
print('Final controlled runs verified against one unchanged product.',flush=True)
