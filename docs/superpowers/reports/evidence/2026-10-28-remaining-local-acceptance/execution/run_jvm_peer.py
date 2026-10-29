import subprocess,os,json,signal,time
from pathlib import Path
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player')
out=Path('/private/tmp/yl-local-acceptance')
cmd=['/opt/homebrew/bin/ffmpeg','-nostdin','-hide_banner','-loglevel','warning','-re','-stream_loop','-1','-i',str(root/'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv'),'-c:v','libx264','-preset','ultrafast','-b:v','4M','-minrate','4M','-maxrate','4M','-bufsize','8M','-x264-params','nal-hrd=cbr:force-cfr=1','-an','-f','flv','rtmp://127.0.0.1:19350/live/burst']
(out/'burst-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (out/'burst-publisher.log').open('w') as log:
 pub=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 try:
  time.sleep(2)
  assert pub.poll() is None
  env=dict(os.environ,YL_RTMP_PEER_PORT='19350',JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',ANDROID_HOME='/opt/homebrew/share/android-commandlinetools')
  cmd=['./gradlew',':yl_player_android:testDebugUnitTest','--offline','--stacktrace']
  (out/'jvm-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
  with (out/'jvm.log').open('w') as f:code=subprocess.run(cmd,cwd=root/'packages/yl_player_android/example/android',env=env,stdout=f,stderr=subprocess.STDOUT,timeout=1200).returncode
 finally:
  if pub.poll() is None:os.killpg(pub.pid,signal.SIGTERM)
  try:pub.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(pub.pid,signal.SIGKILL);pub.wait(timeout=5)
  (out/'burst-cleanup.json').write_text(json.dumps(dict(exited=pub.poll() is not None,returncode=pub.returncode))+'\n')
raise SystemExit(code)
