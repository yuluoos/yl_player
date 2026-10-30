from pathlib import Path
import json,subprocess,time
root=Path.cwd();out=Path('/private/tmp/yl-audio-admission');example=root/'packages/yl_player/example'
commands=[('ios-config',['/Users/yy2021_8689/flutter/bin/flutter','build','ios','--simulator','--debug','--config-only','--no-pub'],example,240),('ios-build',['xcodebuild','build-for-testing','CODE_SIGNING_ALLOWED=NO','ENABLE_TESTABILITY=YES','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','-quiet','-sdk','iphonesimulator','-workspace',str(example/'ios/Runner.xcworkspace'),'-scheme','Runner','-derivedDataPath',str(out/'derived-ios'),'-destination','generic/platform=iOS Simulator'],root,600)]
results=[]
for name,cmd,cwd,deadline in commands:
 start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:
  try: rc=subprocess.run(cmd,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,timeout=deadline).returncode
  except subprocess.TimeoutExpired:rc=124
 results.append({'name':name,'command':cmd,'cwd':str(cwd),'exit':rc,'seconds':round(time.monotonic()-start,3)})
 (out/'ios-build-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print(name,rc,flush=True)
 if rc:raise SystemExit(rc)
