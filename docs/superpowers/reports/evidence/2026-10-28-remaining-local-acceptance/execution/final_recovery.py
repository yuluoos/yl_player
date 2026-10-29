from pathlib import Path
import os,subprocess,json,time,shutil,hashlib
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player');out=Path('/private/tmp/yl-local-acceptance')
env=dict(os.environ,JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',ANDROID_HOME='/opt/homebrew/share/android-commandlinetools')
for k in ['YL_ANDROID_SKIP_JVM','YL_ANDROID_DEVICE_ID','YL_ANDROID_API']:env.pop(k,None)
env['PATH']=str(out/'venv/bin')+':'+env['PATH']
for key in ['OPUS','DAV1D','FFMPEG']:env['YL_'+key+'_ARCHIVE']=str(out/'downloads'/key)
env['YL_FFMPEG_SIGNATURE']=str(out/'downloads/FFMPEG_SIGNATURE');env['YL_RUN_DECODE_PROBE']='1'
results=[]
def run(name,cmd,cwd=root,extra=None,timeout=1800):
 print('START '+name,flush=True);r=dict(name=name,command=cmd,cwd=str(cwd));results.append(r)
 with (out/(name+'.log')).open('w') as f:
  start=time.monotonic()
  try:r['exitCode']=subprocess.run(cmd,cwd=cwd,env=dict(env,**(extra or {})),stdout=f,stderr=subprocess.STDOUT,timeout=timeout).returncode
  except subprocess.TimeoutExpired:r['exitCode']=124;r['timedOut']=True
  r['elapsedSeconds']=time.monotonic()-start
 (out/'recovery-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(r['exitCode']),flush=True)
 return r['exitCode']
properties=root/'packages/yl_player_android/example/android/gradle/wrapper/gradle-wrapper.properties'
before=hashlib.sha256(properties.read_bytes()).hexdigest()
run('android-config-only',['flutter','build','apk','--debug','--config-only','--no-pub'],root/'packages/yl_player_android/example')
(out/'wrapper-configuration.json').write_text(json.dumps(dict(propertiesBefore=before,propertiesAfter=hashlib.sha256(properties.read_bytes()).hexdigest(),wrapperPresent=(properties.parents[2]/'gradlew').exists()),indent=2)+'\n')
run('foundation-final',['sh','tool/check_foundation.sh'])
# Preserve original failed-launch evidence before the retry uses new output files.
retry=out/'jvm-retry';retry.mkdir(exist_ok=False)
script=(out/'run_jvm_peer.py').read_text().replace("out=Path('/private/tmp/yl-local-acceptance')", "out=Path('/private/tmp/yl-local-acceptance/jvm-retry')")
(retry/'run.py').write_text(script)
run('jvm-peer-final',['python3','tool/rtmp_acceptance/run.py','--','python3',str(retry/'run.py')],timeout=1500)
for suite in ['android_session_replacement','android_multi_player_rollback','state_update_cadence']:
 run(suite+'-final',['sh','tool/run_android_integration.sh','integration_test/'+suite+'_test.dart'],root/'packages/yl_player/example',extra=dict(YL_ANDROID_DEVICE_ID='emulator-5580',YL_ANDROID_API='36'))
# Remaining consumer/resolver/packaging checks use the same isolated environment.
run('extra-matrix',['python3',str(out/'final_extra.py')],timeout=2400)
