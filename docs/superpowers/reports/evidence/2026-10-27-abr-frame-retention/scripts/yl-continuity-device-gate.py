from pathlib import Path
import subprocess,json,time
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player')
out=Path('/private/tmp/yl-continuity-device');out.mkdir(exist_ok=False)
deadline=time.monotonic()+650
while not Path('/private/tmp/yl-continuity-runs/auto-pause/receipt.json').exists():
 if time.monotonic()>deadline: raise RuntimeError('simulator observations still running; device build deferred')
 time.sleep(2)
cmd=['xcodebuild','build-for-testing','-quiet','ENABLE_TESTABILITY=YES','DEVELOPMENT_TEAM=JAKM34U2X8','-sdk','iphoneos','-configuration','Debug','-workspace','packages/yl_player/example/ios/Runner.xcworkspace','-scheme','Runner','-destination','platform=iOS,id=00008140-000C49CC3493001C','-derivedDataPath','/private/tmp/yl-continuity-device-build']
with (out/'existing-signing.log').open('w') as log:p=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=600)
results=[dict(name='existing-signing',command=cmd,exitCode=p.returncode)];(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('existing-signing',p.returncode,flush=True)
if p.returncode==0:
 cmd=['xcodebuild','test-without-building','-quiet','ENABLE_TESTABILITY=YES','DEVELOPMENT_TEAM=JAKM34U2X8','-sdk','iphoneos','-configuration','Debug','-workspace','packages/yl_player/example/ios/Runner.xcworkspace','-scheme','Runner','-destination','platform=iOS,id=00008140-000C49CC3493001C','-parallel-testing-enabled','NO','-derivedDataPath','/private/tmp/yl-continuity-device-build','-resultBundlePath',str(out/'contracts.xcresult'),'-only-testing:RunnerTests/YlDashResourceLoaderTests','-only-testing:RunnerTests/YlAppleSessionTests','-only-testing:RunnerTests/YlApplePublicationTests']
 with (out/'contracts.log').open('w') as log:p=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=360)
 results.append(dict(name='contracts',command=cmd,exitCode=p.returncode));(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('contracts',p.returncode,flush=True)
