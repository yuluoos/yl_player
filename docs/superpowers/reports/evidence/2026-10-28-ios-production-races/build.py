from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-production-races');mode=sys.argv[1]
if mode=='ios':cmd=json.loads(Path('/private/tmp/yl-production-recovery/first-ios-build-command.json').read_text())
else:cmd=[v.replace('/private/tmp/yl-postcommit-failure/final-macos-contracts.xcresult',str(r/'macos-contracts.xcresult')) for v in json.loads(Path('/private/tmp/yl-postcommit-failure/final-macos-contracts-command.json').read_text())]
(r/(mode+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/(mode+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/(mode+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print(mode,p.returncode)
