import sys,subprocess,os,json,shutil,time
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player');out=Path(__file__).parent
sys.path.insert(0,str(root/'tool/playback_network'))
from live_fixture import LiveFixture,SOURCE,SOURCE_SHA256
flutter='/Users/yy2021_8689/flutter/bin/flutter'
results=[]
for name,protocol,test,relay_enabled in [('hls-switch','hls','live_mode_switch_test.dart',True),('flv-switch','flv','live_mode_switch_test.dart',True),('hls-resume','hls','hls_long_pause_resume_test.dart',False)]:
 run='p04-merge-'+name; folder=out/name;folder.mkdir()
 started=time.time(); relay=None
 with LiveFixture(protocol,SOURCE,folder/'source',run,shutil.which('ffmpeg')) as fixture:
  port=fixture.port
  if relay_enabled:
   cmd=[sys.executable,'-B',str(root/'tool/playback_network/live_relay.py'),'--protocol',protocol,'--run-id',run,'--media-hash',SOURCE_SHA256,'--upstream-port',str(port),'--port','0','--profile','stall-and-recover-v1','--log',str(folder/'connections.jsonl'),'--receipt',str(folder/'relay-receipt.json')]
   relay=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=(folder/'relay-error.log').open('w'),text=True)
   info=json.loads(relay.stdout.readline());port=info['port'];(folder/'relay-start.json').write_text(json.dumps(info,indent=2))
  url=f'http://127.0.0.1:{port}/live.'+('m3u8' if protocol=='hls' else 'flv')
  cmd=[flutter,'test','--no-pub','integration_test/'+test,'-d','macos','--dart-define=YL_LIVE_RUN='+run,'--dart-define=YL_LIVE_PROTOCOL='+protocol,'--dart-define=YL_LIVE_URL='+url,'--dart-define=P04_HLS='+url,'--dart-define=YL_LIVE_OWNED=true','--dart-define=YL_LIVE_MEDIA_SHA256='+SOURCE_SHA256]
  if relay_enabled: cmd+=['--dart-define=YL_LIVE_PROFILE='+info['profileId'],'--dart-define=YL_LIVE_PROFILE_SHA256='+info['profileHash']]
  (folder/'command.json').write_text(json.dumps(cmd,indent=2))
  try:
   with (folder/'capture.log').open('w') as log:
    try: code=subprocess.run(cmd,cwd=root/'packages/yl_player/example',stdout=log,stderr=subprocess.STDOUT,timeout=480).returncode
    except subprocess.TimeoutExpired: code=124
  finally:
   if relay:
    relay.terminate();relay.wait(timeout=20)
 if relay_enabled:
  scmd=[sys.executable,'-B',str(root/'tool/playback_network/summarize_live.py'),'--capture',str(folder/'capture.log'),'--connections',str(folder/'connections.jsonl'),'--receipt',str(folder/'relay-receipt.json'),'--exit-code',str(code),'--output',str(folder/'summary.json')]
  with (folder/'summary.log').open('w') as log: summary_code=subprocess.run(scmd,stdout=log,stderr=subprocess.STDOUT).returncode
 else: summary_code=None
 row=dict(name=name,exitCode=code,summaryExitCode=summary_code,seconds=round(time.time()-started,2),sourceCleaned=fixture.receipt['cleaned']);results.append(row)
 (out/'live-results.json').write_text(json.dumps(results,indent=2));print(json.dumps(row),flush=True)
