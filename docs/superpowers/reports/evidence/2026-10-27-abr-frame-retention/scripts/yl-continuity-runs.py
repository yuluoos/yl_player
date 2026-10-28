from pathlib import Path
import subprocess,json,time,hashlib
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player')
out=Path('/private/tmp/yl-continuity-runs'); out.mkdir(exist_ok=False)
planned=[('baseline','none','normal'),('auto','auto-reload','normal'),('auto-repeat','auto-reload','normal'),('auto-pause','auto-reload','pause-first')]
(out/'planned.json').write_text(json.dumps(planned,indent=2)+'\n')
files=['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift','tool/playback_network/abr_accesslog.py','tool/playback_network/network_profile.py','tool/playback_network/prepare_fixture.py','tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift','packages/yl_player/example/ios/RunnerTests/YlDashResourceLoaderTests.swift']
(out/'source-identity.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},indent=2)+'\n')
cmd=['xcodebuild','test-without-building','-quiet','CODE_SIGNING_ALLOWED=NO','ENABLE_TESTABILITY=YES','-sdk','iphonesimulator','-workspace','packages/yl_player/example/ios/Runner.xcworkspace','-scheme','Runner','-destination','platform=iOS Simulator,id=B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8','-parallel-testing-enabled','NO','-derivedDataPath','/private/tmp/yl-continuity-ios','-resultBundlePath','/private/tmp/yl-continuity-ios-contracts.xcresult','-only-testing:RunnerTests/YlDashResourceLoaderTests','-only-testing:RunnerTests/YlAppleSessionTests','-only-testing:RunnerTests/YlApplePublicationTests']
with open('/private/tmp/yl-continuity-ios-contracts.log','w') as log:code=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=360).returncode
(out/'contracts-command.json').write_text(json.dumps(dict(command=cmd,exitCode=code),indent=2)+'\n')
print('CONTRACTS',code,flush=True)
results=[]
for name,action,scenario in planned:
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-continuity-ios/Build/Products','--directory',str(out/name),'--device','B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8','--duration-seconds','120','--recovery-action',action,'--auto-scenario',scenario]
 print('START',name,flush=True);start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:code=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=360).returncode
 results.append(dict(name=name,command=cmd,exitCode=code,seconds=time.monotonic()-start));(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END',name,code,flush=True)
 proof=out/name/'process.json'
 if proof.exists():
  pid=json.loads(proof.read_text())['pid']
  command=['xcrun','simctl','spawn','B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8','log','show','--style','json','--last','5m','--predicate',f'processIdentifier == {pid} AND (eventMessage CONTAINS "PenaltyBox" OR eventMessage CONTAINS "MediaHandleDownloadTimer" OR eventMessage CONTAINS "-12889")']
  p=subprocess.run(command,capture_output=True,text=True,timeout=45);(out/(name+'-system-log.json')).write_text(p.stdout);(out/(name+'-system-log-command.json')).write_text(json.dumps(dict(command=command,exitCode=p.returncode,stderr=p.stderr),indent=2)+'\n')
