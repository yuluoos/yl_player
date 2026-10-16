import gzip,hashlib,json,shutil,sys,subprocess
from pathlib import Path
root=Path.cwd();src=Path('/private/tmp/yl-p03-seek-fix-20261016');dst=root/'docs/superpowers/reports/evidence/2026-10-16-p03-apple-seek-fix'
sys.path.insert(0,str(root/'tool/media_matrix'))
from bound_av import validate
from run_bound_flutter_apple import acceptance
replays={}
for run in sorted(src.iterdir()):
 if not run.is_dir() or not (run/'plan.json').exists():continue
 target=dst/run.name;target.mkdir(parents=True,exist_ok=True)
 for f in run.iterdir():
  if f.is_file():shutil.copy2(f,target/f.name)
 if (run/'rows.json.gz').exists():
  plan=json.loads((run/'plan.json').read_text());rows=json.loads(gzip.decompress((run/'rows.json.gz').read_bytes()))
  raw=validate(plan,rows);status=json.loads((run/'status.json').read_text());saved=json.loads((run/'result.json').read_text())
  combined=acceptance(plan,rows,status,saved['artifactsUnchanged'])
  replays[run.name]={'rawAccepted':raw['scopeAcceptance'],'rawSupported':raw['supportedRows'],'required':raw['requiredRows'],'recordedScopeAcceptance':saved['scopeAcceptance'],'scopeAcceptance':combined['scopeAcceptance'],'frameworkPassed':saved['publicTestPassed'],'runtimeIdentityVerified':saved['runtimeIdentityVerified'],'artifactsUnchanged':saved['artifactsUnchanged'],'runId':plan['runId'],'buildSha256':plan['buildSha256'],'errors':raw['errors']}
for f in src.iterdir():
 if f.is_file() and f.suffix in ('.log','.txt'):
  (dst/(f.name+'.gz')).write_bytes(gzip.compress(f.read_bytes(),mtime=0))
for f in src.iterdir():
 if f.is_file() and f.suffix in ('.json','.md','.sh','.swift','.py'):
  shutil.copy2(f,dst/f.name)
(dst/'replay.json').write_text(json.dumps(replays,indent=2)+'\n')
print(json.dumps({k:{a:b for a,b in v.items() if a not in ('buildSha256','runId')} for k,v in replays.items()},indent=2))
