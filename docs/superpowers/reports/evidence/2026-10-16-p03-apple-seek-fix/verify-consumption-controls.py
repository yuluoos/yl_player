import gzip,json,sys
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player')
scratch=Path('/private/tmp/yl-p03-seek-fix-20261016')
sys.path.insert(0,str(root/'tool/media_matrix'))
from bound_artifacts import verify
from bound_av import validate
from run_bound_flutter_apple import acceptance
app=scratch/'build-public/Build/Products/Debug/yl_player_example.app'
checks={};identities=set();runs=set()
for name in ['consumption-public-final','consumption-framework-negative','consumption-identity-negative','consumption-public-repeat']:
 p=scratch/name
 plan=json.loads((p/'plan.json').read_text());result=json.loads((p/'result.json').read_text());status=json.loads((p/'status.json').read_text());product=json.loads((p/'product-files.json').read_text())
 rows=json.loads(gzip.decompress((p/'rows.json.gz').read_bytes()))
 unchanged=verify(app,product);assert unchanged,name
 assert result['statusRunMatches'] and plan['runId'] not in runs,name
 identities.add(product['sha256']);runs.add(plan['runId'])
 raw=validate(plan,rows);combined=acceptance(plan,rows,status,unchanged)
 assert combined['scopeAcceptance']==result['scopeAcceptance'],name
 if name=='consumption-identity-negative':
  assert not rows and not status['identityVerified'] and 'manifest identity mismatch' in status['failure'] and not combined['scopeAcceptance'],name
 elif name=='consumption-framework-negative':
  assert raw['scopeAcceptance'] and raw['supportedRows']==6 and not status['passed'] and not combined['scopeAcceptance'],name
 else:assert raw['scopeAcceptance'] and raw['supportedRows']==6 and status['passed'] and combined['scopeAcceptance'],name
 checks[name]={'rawAccepted':raw['scopeAcceptance'],'supportedRows':raw['supportedRows'],'frameworkPassed':status['passed'],'scopeAcceptance':combined['scopeAcceptance'],'runtimeIdentityVerified':status['identityVerified'],'hostProductUnchangedAtAudit':unchanged,'buildSha256':product['sha256'],'runId':plan['runId']}
assert len(identities)==1 and len(runs)==4
(scratch/'final-controls-audit.json').write_text(json.dumps(checks,indent=2)+'\n')
print('Four distinct runs; one unchanged bundle; two positives and both intended negative controls verified.')
