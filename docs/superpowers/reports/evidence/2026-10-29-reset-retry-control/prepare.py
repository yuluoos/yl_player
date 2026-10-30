from pathlib import Path
import json,hashlib,copy,sys,subprocess
r=Path('/private/tmp/yl-reset-retry-control');old=Path('docs/superpowers/reports/evidence/2026-10-29-loopback-error-source');prev='/private/tmp/yl-loopback-error-source'
for name in ['analyze.py','bytes.py','request-analysis.py','high-boundary.py','error-analysis.py','offline.py','readiness.py','archive.py','native-attachments.py','bind-native.py']:
 s=(old/name).read_text().replace(prev,str(r)).replace('2026-10-29-loopback-error-source','2026-10-29-reset-retry-control').replace("['budget-throttle','normal']","['budget-throttle','budget-mild','normal']").replace("('budget-throttle','normal')","('budget-throttle','budget-mild','normal')")
 if name=='request-analysis.py':s=s.replace("[('previous-budget',Path('/private/tmp/yl-final-media-budget/media/pause-resume'))]+",'')
 (r/name).write_text(s)
s=(old/'run-media.py').read_text().replace(prev,str(r)).replace("['budget-throttle','normal']","['budget-throttle','budget-mild','normal']")
s=s.replace("profile='repeat-throttle-budget-diagnostic-v1' if name=='budget-throttle' else 'repeat-stall-budget-diagnostic-v1'","profile={'budget-throttle':'repeat-throttle-budget-diagnostic-v1','budget-mild':'repeat-mild-budget-diagnostic-v1','normal':'repeat-stall-budget-diagnostic-v1'}[name]")
s=s.replace('/private/tmp/yl-production-exercise/ios-build/Build/Products',str(r/'ios-build/Build/Products'))
(r/'run-media.py').write_text(s)
profiles=json.loads((old/'profiles.json').read_text());base=next(p for p in profiles['profiles'] if p['id']=='repeat-throttle-budget-diagnostic-v1');mild=copy.deepcopy(base);mild['id']='repeat-mild-budget-diagnostic-v1';assert mild['steps'][3]['bytesPerSecond']==50000;mild['steps'][3]['bytesPerSecond']=75000;profiles['profiles'].append(mild);(r/'profiles.json').write_text(json.dumps(profiles,indent=2)+'\n')
(r/'profile-delta.json').write_text(json.dumps(dict(baseline=base,control=mild,onlyDifference='step3.bytesPerSecond 50000->75000 plus descriptive profile id',controlHasNoErrors=None,controlHasSecondDownshift=None,acceptanceThresholdsUnchanged=True),indent=2)+'\n')
source=json.loads((old/'source-identity.json').read_text());(r/'source-identity.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in source},indent=2)+'\n')
sys.path.insert(0,'tool/release_readiness');import check
(r/'production-source.json').write_text(json.dumps(check.source_snapshot(Path.cwd()),indent=2)+'\n')
(r/'source.patch').write_bytes(subprocess.check_output(['git','diff']))
