from pathlib import Path
import json,time,subprocess
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player'); receipt=Path('/private/tmp/yl-auto-20261027/auto-pause/receipt.json')
end=time.monotonic()+200
while not receipt.exists():
 if time.monotonic()>end:raise RuntimeError('preceding owned run not complete')
 time.sleep(1)
r=json.loads(receipt.read_text());assert r['binaryIdentityUnchanged'] and r['ownedProcessExited']
cmd=['xcodebuild','build-for-testing','-quiet','CODE_SIGNING_ALLOWED=NO','ENABLE_TESTABILITY=YES','-sdk','iphonesimulator','-configuration','Debug','-workspace','packages/yl_player/example/ios/Runner.xcworkspace','-scheme','Runner','-destination','platform=iOS Simulator,id=B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8','-derivedDataPath','/private/tmp/yl-remaining-20261026-ios']
with open('/private/tmp/yl-auto-ios-reviewed-build.log','w') as f:code=subprocess.run(cmd,cwd=root,stdout=f,stderr=subprocess.STDOUT).returncode
Path('/private/tmp/yl-auto-ios-reviewed-build.exit').write_text(str(code)+'\n');assert code==0
script=Path('/private/tmp/yl-auto-runs.py').read_text().replace('out.mkdir(exist_ok=False)','out.mkdir(exist_ok=True)').replace("out/'source-identity.json'","out/'final-source-identity.json'").replace("[('baseline','none','normal'),('auto','auto-reload','normal'),('auto-repeat','auto-reload','normal'),('auto-pause','auto-reload','pause-first')]","[('auto-final-pause','auto-reload','pause-first')]").replace("out/'results.json'","out/'final-results.json'")
Path('/private/tmp/yl-auto-reviewed-run.py').write_text(script)
subprocess.run(['python3','/private/tmp/yl-auto-reviewed-run.py'],cwd=root,check=True)
