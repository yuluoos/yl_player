from pathlib import Path
import subprocess,json,time,os
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player');out=Path(__file__).parent;example=root/'packages/yl_player/example'
classes=['YlAppleDecoderRestorationTests','YlAppleRestorationTests','YlAppleCommandOrderingTests','YlAppleAcceptedIntentTests','YlAppleHostTests','YlApplePublicationTests','YlVorbisDelayTests','YlSoftwareDecodeBudgetTests','YlSoftwareVideoLifecycleTests','YlContainerOutputTests']
cmd=['xcodebuild','test','-quiet','CODE_SIGNING_ALLOWED=NO','ENABLE_TESTABILITY=YES','-sdk','macosx','-workspace','macos/Runner.xcworkspace','-scheme','Runner','-parallel-testing-enabled','NO','-derivedDataPath',str(example/'build/native-macos-tests'),'-destination','platform=macOS,arch=arm64','-resultBundlePath',str(out/'native-final.xcresult')]+['-only-testing:RunnerTests/'+v for v in classes]
checks=[('macos-native-final',['python3','-B',str(root/'tool/run_with_display_awake.py')]+cmd,example)]
rows=[]
for name,cmd,cwd in checks:
 t=time.time()
 with (out/(name+'.log')).open('w') as log:
  try:code=subprocess.run(cmd,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,timeout=1000).returncode
  except subprocess.TimeoutExpired:code=124
 rows.append(dict(name=name,cmd=cmd,cwd=str(cwd),exitCode=code,seconds=round(time.time()-t,2)))
 (out/'apple-final-results.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows[-1]),flush=True)
