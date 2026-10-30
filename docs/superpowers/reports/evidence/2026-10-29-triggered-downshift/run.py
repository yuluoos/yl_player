from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-triggered-downshift');n=sys.argv[1];cmd=json.loads((r/(n+'-command.json')).read_text())
with (r/(n+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(n+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
if n!='ios-build':
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(n+'.xcresult'))],capture_output=True,text=True);(r/(n+'-'+kind+'.json')).write_text(q.stdout)
print(n,p.returncode)
