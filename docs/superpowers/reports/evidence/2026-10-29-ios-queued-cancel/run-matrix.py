from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-queued-cancel');name=sys.argv[1];kind=name.removesuffix('-repeat');source={'ios-build':'ios-build-command.json','ios-final':'ios-final-command.json','macos-final':'macos-final-command.json'}[kind]
cmd=json.loads((Path('/private/tmp/yl-budget-metrics')/source).read_text());cmd=[c.replace('/private/tmp/yl-budget-metrics/'+kind+'.xcresult',str(r/(name+'.xcresult'))) for c in cmd]
(r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(name+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
if name!='ios-build':
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(name+'.xcresult'))],capture_output=True,text=True);(r/(name+'-'+kind+'.json')).write_text(q.stdout)
print(name,p.returncode)
