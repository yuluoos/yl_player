from pathlib import Path
import subprocess,json,time,os
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player'); out=Path(__file__).parent; example=root/'packages/yl_player/example'; flutter='/Users/yy2021_8689/flutter/bin/flutter'
checks=[
 ('subtitle-completed-seek',['python3','-B',str(root/'tool/run_with_display_awake.py'),flutter,'test','--no-pub','--reporter','expanded','integration_test/subtitle_completed_seek_test.dart','-d','macos']),
 ('ios-config',[flutter,'build','ios','--simulator','--debug','--no-pub','--config-only']),
 ('ios-arm64-build',['xcodebuild','-quiet','-workspace','ios/Runner.xcworkspace','-scheme','Runner','-configuration','Debug','-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','build'])
]
rows=[]
for name,cmd in checks:
 t=time.time()
 with (out/(name+'.log')).open('w') as log:
  try:code=subprocess.run(cmd,cwd=example,stdout=log,stderr=subprocess.STDOUT,timeout=900).returncode
  except subprocess.TimeoutExpired:code=124
 rows.append(dict(name=name,cmd=cmd,cwd=str(example),exitCode=code,seconds=round(time.time()-t,2)))
 (out/'final-build-results.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows[-1]),flush=True)
