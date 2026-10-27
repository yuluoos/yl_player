import os,sys,subprocess,json,time,signal
from urllib.parse import urlparse
from pathlib import Path
root=Path(sys.argv[1]);out=Path('/private/tmp/yl-abr-recovery-20261027-runs');out.mkdir(exist_ok=False)
python='/private/tmp/yl-remaining-20261026-python/bin/python';flutter='/Users/yy2021_8689/flutter/bin/flutter'
fixtures={};results=[]
for seconds in (40,120):
 fixture=out/('fixture-'+str(seconds))
 result=subprocess.run([python,'-B','tool/playback_network/prepare_fixture.py','--output',str(fixture),'--duration-seconds',str(seconds)],cwd=root,capture_output=True,text=True)
 (out/('fixture-'+str(seconds)+'-receipt.json')).write_text(result.stdout)
 if result.returncode:raise SystemExit(result.returncode)
 fixtures[seconds]=(fixture,json.loads(result.stdout)['manifestSha256'])
def stop(p):
 if p.poll() is None:
  os.killpg(p.pid,signal.SIGINT)
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
for platform,target in [('ios','B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8'),('android','emulator-5580')]:
 for seconds,repeat in [(40,1),(120,1),(120,2)]:
  mode='auto';fixture,media=fixtures[seconds]
  name=platform+'-'+mode+'-'+str(seconds)+'-r'+str(repeat);run=out/name;run.mkdir();run_id='recovery-20261027-'+name
  print('START '+name,flush=True);server=None;player=None;exitcode=None;reverse_port=None
  with (run/'server.jsonl').open('w') as serverlog,(run/'capture.log').open('w') as log:
   try:
    server=subprocess.Popen([python,'-B','tool/playback_network/network_profile.py','--root',str(fixture),'--port','0','--start-on-first-get','--run-id',run_id,'--log',str(run/'requests.jsonl')],cwd=root,stdout=serverlog,stderr=subprocess.STDOUT,start_new_session=True)
    deadline=time.monotonic()+10
    while not (run/'server.jsonl').stat().st_size:
     if server.poll() is not None or time.monotonic()>deadline:raise RuntimeError('fixture failed to start')
     time.sleep(.05)
    info=json.loads((run/'server.jsonl').read_text().splitlines()[0])
    if platform=='android':
     reverse_port=str(urlparse(info['url']).port)
     subprocess.run(['/opt/homebrew/share/android-commandlinetools/platform-tools/adb','-s',target,'reverse','tcp:'+reverse_port,'tcp:'+reverse_port],check=True,stdout=log,stderr=subprocess.STDOUT)
    command=[flutter,'test','--no-pub','integration_test/abr_network_profile_test.dart','-d',target,'--reporter','expanded','--dart-define=YL_ABR_RUN='+run_id,'--dart-define=YL_ABR_MODE='+mode,'--dart-define=YL_ABR_URL='+info['url'],'--dart-define=YL_ABR_PROFILE='+info['profile'],'--dart-define=YL_ABR_PROFILE_SHA256='+info['profileSha256'],'--dart-define=YL_ABR_MEDIA_SHA256='+media,'--dart-define=YL_ABR_PROGRAMME_SECONDS='+str(seconds)]
    (run/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    player=subprocess.Popen(command,cwd=root/'packages/yl_player/example',stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:exitcode=player.wait(timeout=600)
    except subprocess.TimeoutExpired:exitcode=124;stop(player)
   finally:
    if player:stop(player)
    if server:stop(server)
    if reverse_port:subprocess.run(['/opt/homebrew/share/android-commandlinetools/platform-tools/adb','-s',target,'reverse','--remove','tcp:'+reverse_port],stdout=log,stderr=subprocess.STDOUT,timeout=10)
  (run/'exit-code').write_text(str(exitcode)+'\n')
  summary=subprocess.run([python,'-B','tool/playback_network/summarize_capture.py','--capture',str(run/'capture.log'),'--requests',str(run/'requests.jsonl'),'--server-stdout',str(run/'server.jsonl'),'--exit-code',str(exitcode),'--output',str(run/'summary.json')],cwd=root,capture_output=True,text=True)
  (run/'summary-command.log').write_text(summary.stdout+summary.stderr)
  results.append(dict(name=name,playerExit=exitcode,summaryExit=summary.returncode))
  (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(results[-1]),flush=True)
