from pathlib import Path
import subprocess,os,json,time
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player')
out=Path('/private/tmp/yl-local-acceptance')
env=dict(os.environ,JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',ANDROID_HOME='/opt/homebrew/share/android-commandlinetools')
env['PATH']=str(out/'venv/bin')+':'+env['PATH']
for key in ['OPUS','DAV1D','FFMPEG']:env['YL_'+key+'_ARCHIVE']=str(out/'downloads'/key)
env['YL_FFMPEG_SIGNATURE']=str(out/'downloads/FFMPEG_SIGNATURE')
env.update(YL_ANDROID_SKIP_JVM='1',YL_ANDROID_DEVICE_ID='emulator-5580',YL_ANDROID_API='36')
results=[]
def run(name,cmd,cwd=root,timeout=1800):
 print('START '+name,flush=True);start=time.monotonic()
 row=dict(name=name,command=cmd,cwd=str(cwd));results.append(row)
 with (out/(name+'.log')).open('w') as f:
  try:row['exitCode']=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=timeout).returncode
  except subprocess.TimeoutExpired:row['timedOut']=True;row['exitCode']=124
 row['elapsedSeconds']=time.monotonic()-start;(out/'final-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(row['exitCode']),flush=True)
run('abr-repeat',['python3',str(out/'run_abr.py'),'caps:40:1','fixed:40:1','auto:40:2','auto:120:2','caps:40:2','fixed:40:2'],timeout=1800)
# Reused long diagnostic is temporary, byte-identical to an already committed test.
(root/'packages/yl_player/example/integration_test/local_long_diagnostic_test.dart').unlink()
run('foundation',['sh','tool/check_foundation.sh'],timeout=1800)
run('android-example-dependencies',['flutter','pub','get'],root/'packages/yl_player_android/example')
run('jvm-peer',['python3','tool/rtmp_acceptance/run.py','--','python3',str(out/'run_jvm_peer.py')],timeout=1500)
run('android-device',['sh','tool/check_native_android.sh'],timeout=1800)
