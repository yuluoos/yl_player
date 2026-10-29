from pathlib import Path
import subprocess,json,sys
r=Path('/private/tmp/yl-production-races');mode=sys.argv[1]
if mode=='ios':cmd=json.loads(Path('/private/tmp/yl-production-recovery/first-ios-build-command.json').read_text())
else:cmd=[v.replace('/private/tmp/yl-postcommit-failure/final-macos-contracts.xcresult',str(r/'qualified-macos-contracts.xcresult')) for v in json.loads(Path('/private/tmp/yl-postcommit-failure/final-macos-contracts-command.json').read_text())]
if mode!='ios':cmd += ['-only-testing:RunnerTests/'+c for c in ['YlHeaderedProgressivePlaybackTests','YlAppleHlsProbeTests','YlAppleHlsIntentTests','YlAppleTypedBackendTests']]
(r/('qualified-'+mode+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (r/('qualified-'+mode+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/('qualified-'+mode+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print(mode,p.returncode)
