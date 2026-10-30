from pathlib import Path
import json,subprocess,sys
r=Path('/private/tmp/yl-fast-cancel');name=sys.argv[1]
cmd=json.loads(Path('/private/tmp/yl-budget-metrics/metrics-red-command.json').read_text());cmd=[v.replace('/private/tmp/yl-budget-metrics/metrics-red.xcresult',str(r/(name+'.xcresult'))) for v in cmd if not v.startswith('-only-testing:')]
cmd += ['-only-testing:RunnerTests/YlDashResourceLoaderTests/'+v for v in sys.argv[2:]]
(r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(name+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
for kind in ['summary','tests']:
 d=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(name+'.xcresult'))],capture_output=True,text=True);(r/(name+'-'+kind+'.json')).write_text(d.stdout)
print(name,p.returncode)
