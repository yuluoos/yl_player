from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-half-close-fix');n=sys.argv[1]
source='native-green' if n.startswith('native-probe') else ('ios-build' if n.startswith('ios-build') else {'macos-confirm':'macos-final','ios-confirm':'ios-final','macos-fixed':'macos-final','ios-fixed':'ios-final'}.get(n,n))
cmd=json.loads((Path('/private/tmp/yl-transaction-bytes')/(source+'-command.json')).read_text())
cmd=[c.replace('/private/tmp/yl-transaction-bytes/'+source+'.xcresult',str(r/(n+'.xcresult'))) for c in cmd]
if n.startswith('native-probe') or n.endswith('-confirm') and not n.startswith('ios-build'):
 cmd=[c for c in cmd if not c.startswith('-only-testing:')]+['-only-testing:RunnerTests/YlDashResourceLoaderTests/testHalfClosedClientReceivesCompleteDirectAndProxyResponses']
(r/(n+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(n+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(n+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n')
if not n.startswith('ios-build'):
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/(n+'.xcresult'))],capture_output=True,text=True);(r/(n+'-'+kind+'.json')).write_text(q.stdout)
print(n,p.returncode)
