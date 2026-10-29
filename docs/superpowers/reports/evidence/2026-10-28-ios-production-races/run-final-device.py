from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-production-races')
cmd=json.loads(Path('/private/tmp/yl-postcommit-failure/final-device-contracts-command.json').read_text())
cmd=[x.replace('/private/tmp/yl-postcommit-failure/final-device-contracts.xcresult',str(r/'final-device-contracts.xcresult')) for x in cmd]
(r/'final-device-contracts-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'final-device-contracts.log').open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'final-device-contracts-result.json').write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print('device',p.returncode)
