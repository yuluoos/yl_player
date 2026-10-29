from pathlib import Path
import os,subprocess,json,time
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player');out=Path('/private/tmp/yl-local-acceptance')
env=dict(os.environ,JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',ANDROID_HOME='/opt/homebrew/share/android-commandlinetools',YL_CONSUMER_OUTPUT=str(out/'consumer'),YL_PUBLICATION_LOG_DIR=str(out/'publication-logs'))
env['PATH']=str(out/'venv/bin')+':'+env['PATH']
env['YL_RUN_DECODE_PROBE']='1'
results=[]
for name,cmd,cwd in [('decode-probe',['python3','-B','-m','unittest','discover','-s','tool/dolby_reference','-p','test_decode_probe.py'],root),('source-resolver',['flutter','test','--no-pub','test'],root/'packages/yl_player_source_resolver'),('android-consumer',['sh','tool/check_consumers.sh','--android-only'],root),('publication',['sh','tool/check_publication.sh','--archives-only'],root),('compositor',['sh','tool/playback_benchmark/check_compositor_probe.sh'],root)]:
 print('START '+name,flush=True);r=dict(name=name,command=cmd,cwd=str(cwd));results.append(r)
 with (out/(name+'.log')).open('w') as f:
  start=time.monotonic()
  try:r['exitCode']=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=1200).returncode
  except subprocess.TimeoutExpired:r['exitCode']=124;r['timedOut']=True
  r['elapsedSeconds']=time.monotonic()-start
 (out/'extra-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(r['exitCode']),flush=True)
