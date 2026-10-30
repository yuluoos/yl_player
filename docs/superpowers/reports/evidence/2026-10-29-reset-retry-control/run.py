from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-reset-retry-control');old=Path('docs/superpowers/reports/evidence/2026-10-29-loopback-error-source');n=sys.argv[1]
cmd=json.loads((old/(n+'-command.json')).read_text())
cmd=[c.replace('/private/tmp/yl-loopback-error-source',str(r)).replace('/private/tmp/yl-production-exercise/ios-build',str(r/'ios-build')).replace('/private/tmp/yl-budget-metrics/macos-build',str(r/'macos-build')) for c in cmd]
(r/(n+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(n+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(n+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
if n!='ios-build':
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(n+'.xcresult'))],capture_output=True,text=True);(r/(n+'-'+kind+'.json')).write_text(q.stdout)
print(n,p.returncode)
