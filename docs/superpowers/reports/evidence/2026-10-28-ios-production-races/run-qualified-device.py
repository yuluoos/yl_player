from pathlib import Path
import subprocess,json,hashlib
r=Path('/private/tmp/yl-production-races')
products=Path('/private/tmp/yl-public-policy-ios/Build/Products')
expected=json.loads((r/'media/reviewed-seek-prepared/receipt.json').read_text())['binaryHashes']
def verify_binary():
 for name,h in expected.items():assert hashlib.sha256((products/name).read_bytes()).hexdigest()==h,name
verify_binary()
cmd=json.loads(Path('/private/tmp/yl-postcommit-failure/final-device-contracts-command.json').read_text())
cmd=[x.replace('/private/tmp/yl-postcommit-failure/final-device-contracts.xcresult',str(r/'qualified-device-contracts.xcresult')) for x in cmd]
cmd += ['-only-testing:RunnerTests/'+c for c in ['YlHeaderedProgressivePlaybackTests','YlAppleHlsProbeTests','YlAppleHlsIntentTests','YlAppleTypedBackendTests']]
(r/'qualified-device-contracts-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'qualified-device-contracts.log').open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'qualified-device-contracts-result.json').write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print('device',p.returncode)

verify_binary()
(r/'qualified-device-binary-binding.json').write_text(json.dumps(dict(beforeAndAfterMatch=True,binaryHashes=expected),indent=2)+'\n')
