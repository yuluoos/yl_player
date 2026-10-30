from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-loopback-error-source');n=sys.argv[1]
source='macos-final' if n.startswith('native-') else n
cmd=json.loads((Path('/private/tmp/yl-timeout-overflow')/(source+'-command.json')).read_text())
cmd=[c.replace('/private/tmp/yl-timeout-overflow/'+source+'.xcresult',str(r/(n+'.xcresult'))) for c in cmd]
if n.startswith('native-'):
 cmd=[c for c in cmd if not c.startswith('-only-testing:')]+['-only-testing:RunnerTests/YlDashResourceLoaderTests/testProxyRequestTimingRecordsRealCancellationBeforeUpstreamResponse']
(r/(n+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(n+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(n+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
if n!='ios-build':
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(n+'.xcresult'))],capture_output=True,text=True);(r/(n+'-'+kind+'.json')).write_text(q.stdout)
print(n,p.returncode)
