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
 (out/'followup-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(r['exitCode']),flush=True)
 return r['exitCode']
run('foundation-resume',['sh',str(out/'foundation-resume.sh')])
run('final-analyze',['flutter','analyze'])
for suite in ['android_session_replacement','android_multi_player_rollback','state_update_cadence']:
 run(suite+'-retry',['sh',str(root/'tool/run_android_integration.sh'),'integration_test/'+suite+'_test.dart'],root/'packages/yl_player/example',extra=dict(YL_ANDROID_DEVICE_ID='emulator-5580',YL_ANDROID_API='36'))
