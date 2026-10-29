from pathlib import Path
import json,subprocess,sys
r=Path('/private/tmp/yl-resume-timeout');name=sys.argv[1]
cmd=json.loads(Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-races/qualified-macos-command.json').read_text())
cmd=[v.replace('/private/tmp/yl-public-policy-macos','/private/tmp/yl-recovery-landing/macos-build').replace('/private/tmp/yl-production-races/qualified-macos-contracts.xcresult',str(r/(name+'.xcresult'))) for v in cmd]
if len(sys.argv)>2:cmd=[v for v in cmd if not v.startswith('-only-testing:')]+['-only-testing:RunnerTests/YlDashResourceLoaderTests/'+v for v in sys.argv[2:]]
(r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(name+'-result.json')).write_text(json.dumps({'exitCode':result.returncode})+'\n')
print(name,result.returncode)
if (r/(name+'.xcresult')).exists():
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(name+'.xcresult'))],capture_output=True,text=True)
  (r/(name+'-'+kind+'.json')).write_text(q.stdout)
