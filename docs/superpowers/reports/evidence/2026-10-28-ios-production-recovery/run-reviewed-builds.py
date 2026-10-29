from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-production-recovery');mode=sys.argv[1]
if mode=='ios':cmd=json.loads((r/'first-ios-build-command.json').read_text());name='reviewed-ios-build'
else:
 cmd=json.loads(Path('/private/tmp/yl-postcommit-failure/final-macos-contracts-command.json').read_text());cmd=[x.replace('/private/tmp/yl-postcommit-failure/final-macos-contracts.xcresult',str(r/'reviewed-macos-contracts.xcresult')) for x in cmd];name='reviewed-macos-contracts'
(r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(name+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print(name,p.returncode)
