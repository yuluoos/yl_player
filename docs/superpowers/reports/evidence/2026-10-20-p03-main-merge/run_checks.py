import subprocess,json,time,os,sys
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player'); out=Path(__file__).parent
flutter='/Users/yy2021_8689/flutter/bin/flutter'
mode=sys.argv[1]
checks=[]
if mode=='dart':
 checks=[('analyze',[flutter,'analyze','--no-pub'],root)]
 for p in ['yl_player_platform_interface','yl_player','yl_player_android','yl_player_apple','yl_player_media_delivery','yl_player_cast','yl_player_cast_player_adapter']:
  checks.append((p,[flutter,'test','--no-pub','--reporter','expanded',f'packages/{p}/test'],root))
 for p in ['yl_player/example','yl_player_android/example','yl_player_cast/example','yl_player_source_resolver']:
  checks.append((p.replace('/','_'),[flutter,'test','--no-pub','--reporter','expanded','test'],root/'packages'/p))
elif mode=='native':
 checks=[('apple-live',['python3','-B','tool/playback_network/check_live_mode_native.py','--flutter-sdk','/Users/yy2021_8689/flutter'],root),('delivery-native',['python3','-B','tool/media_delivery/run_native_tests.py'],root)]
elif mode=='android':
 checks=[('android-jvm',['sh','tool/check_native_android.sh'],root)]
elif mode=='python':
 checks=[(name,['python3','-B','-m','unittest','discover','-s','tool/'+name,'-p','test_*.py'],root) for name in ['media_matrix','decoder_probe','dash_timeline']]
 checks.append(('public-surface',['python3','-B','-m','unittest','tool.test_public_surface'],root))
env=dict(os.environ,FLUTTER_ROOT='/Users/yy2021_8689/flutter',JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
env['PATH']='/Users/yy2021_8689/flutter/bin:'+env['JAVA_HOME']+'/bin:'+env['PATH']
results=[]
for name,cmd,cwd in checks:
 start=time.time()
 with (out/(name+'.log')).open('w') as log:
  try: code=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1200).returncode
  except subprocess.TimeoutExpired: code=124
 row=dict(name=name,cmd=cmd,cwd=str(cwd),exitCode=code,seconds=round(time.time()-start,2));results.append(row)
 (out/(mode+'-results.json')).write_text(json.dumps(results,indent=2)+'\n')
 print(json.dumps(row),flush=True)
print('DONE',mode,flush=True)
