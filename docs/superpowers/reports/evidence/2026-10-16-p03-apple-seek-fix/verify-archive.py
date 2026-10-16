import gzip,hashlib,json,subprocess,sys
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player');archive=root/'docs/superpowers/reports/evidence/2026-10-16-p03-apple-seek-fix'
sys.path.insert(0,str(root/'tool/media_matrix'))
from bound_av import validate
from run_bound_flutter_apple import acceptance
sources=json.loads((archive/'source-provenance-consumption.json').read_text())
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==sources['base']
assert all(hashlib.sha256((root/f).read_bytes()).hexdigest()==h for f,h in sources['sources'].items())
replay=json.loads((archive/'replay.json').read_text());assert len(replay)==19
for name,expected in replay.items():
 p=archive/name
 plan=json.loads((p/'plan.json').read_text());rows=json.loads(gzip.decompress((p/'rows.json.gz').read_bytes()));status=json.loads((p/'status.json').read_text());result=json.loads((p/'result.json').read_text())
 raw=validate(plan,rows);combined=acceptance(plan,rows,status,result['artifactsUnchanged'])
 assert raw['supportedRows']==expected['rawSupported'] and combined['scopeAcceptance']==expected['scopeAcceptance'],name
summary=json.loads((archive/'native-consumption-verified-summary.json').read_text())
assert summary['passedTests']==43 and summary['failedTests']==0 and summary['skippedTests']==0
checks=json.loads((archive/'final-controls-audit.json').read_text())
assert len(checks)==4 and len({v['buildSha256'] for v in checks.values()})==1 and len({v['runId'] for v in checks.values()})==4
assert all(v['hostProductUnchangedAtAudit'] for v in checks.values())
print('Archive verified: 19 independent histories, 4 final intended outcomes, 43 native tests, unchanged final sources.')
