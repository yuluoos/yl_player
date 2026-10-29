import sys,os,json,subprocess,time,signal,hashlib,importlib.util
from pathlib import Path
ROOT=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player')
OUT=Path('/private/tmp/yl-local-acceptance')
sys.path.insert(0,str(ROOT/'tool/playback_network'))
from network_profile import load_profiles
spec=importlib.util.spec_from_file_location('reused',OUT/'prepare_fixture_reused.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
mod.SOURCE=ROOT/'packages/yl_player/example/assets/test_media/dash_variants'
env=dict(os.environ,JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',ANDROID_HOME='/opt/homebrew/share/android-commandlinetools')
def run(mode,duration,attempt):
 ident=f'local-20261028-{duration}-{mode}-{attempt}'
 dest=OUT/ident;dest.mkdir()
 fixture=OUT/f'fixture-{duration}'
 if not fixture.exists():
  receipt=mod.create(fixture,duration_seconds=duration)
  (OUT/f'fixture-{duration}.json').write_text(json.dumps(receipt,indent=2)+'\n')
 receipt=json.loads((OUT/f'fixture-{duration}.json').read_text())
 profile=load_profiles(ROOT/'tool/playback_network/profiles.json')['down-and-recover-v1']
 port=18791
 command=[sys.executable,'-B',str(ROOT/'tool/playback_network/network_profile.py'),'--root',str(fixture),'--profile',profile.id,'--start-on-first-get','--run-id',ident,'--port',str(port),'--log',str(dest/'requests.jsonl')]
 (dest/'server-command.json').write_text(json.dumps(command,indent=2))
 capture=['/Users/yy2021_8689/flutter/bin/flutter','test','--no-pub','integration_test/abr_network_profile_test.dart' if duration==40 else 'integration_test/local_long_diagnostic_test.dart','-d','emulator-5580','--reporter','expanded']
 for k,v in dict(RUN=ident,MODE=mode,URL=f'http://127.0.0.1:{port}/manifest.mpd',PROFILE=profile.id,PROFILE_SHA256=profile.sha256,MEDIA_SHA256=receipt['manifestSha256'],PROGRAMME_SECONDS=duration).items():capture.append(f'--dart-define=YL_ABR_{k}={v}')
 (dest/'command.json').write_text(json.dumps(capture,indent=2)+'\n')
 sf=(dest/'server.log').open('w');server=subprocess.Popen(command,stdout=sf,stderr=subprocess.STDOUT,env=env,cwd=ROOT)
 result=dict(runId=ident,duration=duration,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),reusedToolsCommit='83deb9ed',physicalDevice=False,baselineComparable=False)
 try:
  for _ in range(100):
   if 'manifestUrl' in (dest/'server.log').read_text() or 'profileSha256' in (dest/'server.log').read_text():break
   if server.poll() is not None:raise RuntimeError('server exited')
   time.sleep(.1)
  subprocess.run(['adb','-s','emulator-5580','reverse',f'tcp:{port}',f'tcp:{port}'],check=True,stdout=subprocess.DEVNULL)
  with (dest/'capture.log').open('w') as cf:
   proc=subprocess.Popen(capture,cwd=ROOT/'packages/yl_player/example',env=env,stdout=cf,stderr=subprocess.STDOUT,start_new_session=True)
   try: result['exitCode']=proc.wait(timeout=600)
   except subprocess.TimeoutExpired:
    result['timedOut']=True;os.killpg(proc.pid,signal.SIGTERM);result['exitCode']=proc.wait(timeout=30)
  apk=ROOT/'packages/yl_player/example/build/app/outputs/flutter-apk/app-debug.apk'
  if apk.exists():result['apkSha256']=hashlib.sha256(apk.read_bytes()).hexdigest()
 finally:
  subprocess.run(['adb','-s','emulator-5580','reverse','--remove',f'tcp:{port}'],stdout=subprocess.DEVNULL)
  if server.poll() is None:server.send_signal(signal.SIGINT)
  result['serverExitCode']=server.wait(timeout=20);sf.close()
  (dest/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 if 'exitCode' in result:
  cmd=[sys.executable,'-B',str(OUT/'summarize_capture_reused.py'),'--capture',str(dest/'capture.log'),'--requests',str(dest/'requests.jsonl'),'--server-stdout',str(dest/'server.log'),'--exit-code',str(result['exitCode']),'--output',str(dest/'summary.json')]
  with (dest/'summary.log').open('w') as f:result['summaryExitCode']=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT).returncode
  (dest/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result),flush=True)
for spec in sys.argv[1:]:
 mode,duration,attempt=spec.split(':');run(mode,int(duration),int(attempt))
