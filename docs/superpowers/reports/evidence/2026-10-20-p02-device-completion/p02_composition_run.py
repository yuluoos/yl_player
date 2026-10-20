from pathlib import Path
import json,subprocess,time,sys,hashlib
root=Path('/Users/yy2021_8689/.codex/worktrees/p02-tracks-subtitles/yl_player')
platform=sys.argv[1]
out=root/'.superpowers/sdd/2026-10-20-p02-device-completion/logs'/(platform+'-composition-'+time.strftime('%Y%m%d-%H%M%S'))
out.mkdir()
helper=None
try:
 if platform=='macos':
  binary=out/'capture-window'
  subprocess.run(['swiftc',str(root/'tool/dash_timeline/capture_window.swift'),'-o',str(binary)],check=True)
  helper=subprocess.Popen(['/opt/homebrew/bin/python3',str(root/'tool/dash_timeline/capture_composition.py'),'--platform','macos','--window-helper',str(binary),'--output',str(out/'pixels')],stdout=subprocess.PIPE,stderr=(out/'capture-helper-errors.log').open('w'),text=True)
  first=helper.stdout.readline()
  url=json.loads(first)['captureUrl']
  (out/'helper-start.json').write_text(first)
  device='macos'
 elif platform=='android':device='emulator-5554';url=None
 args=['/Users/yy2021_8689/flutter/bin/flutter','test','--no-pub','integration_test/subtitle_playback_test.dart','-d',device,'--reporter','expanded']
 if url:args+=['--dart-define=P01_CAPTURE_URL='+url]
 (out/'command.json').write_text(json.dumps(args))
 print('P02_CAPTURE='+str(out),flush=True)
 with (out/'test.log').open('w') as log:
  child=subprocess.Popen(args,cwd=root/'packages/yl_player/example',stdout=log,stderr=subprocess.STDOUT)
  try: code=child.wait(timeout=900)
  except subprocess.TimeoutExpired:
   child.terminate()
   try:child.wait(timeout=10)
   except subprocess.TimeoutExpired:child.kill();child.wait()
   code=124
 (out/'exit-code').write_text(str(code))
 print('P02_EXIT='+str(code),flush=True)
finally:
 if helper:
  helper.terminate(); output,_=helper.communicate(timeout=10)
  (out/'helper.log').write_text(output)
 (out/'cleanup.json').write_text(json.dumps({'captureHelperStopped':helper is None or helper.poll() is not None}))
sys.exit(code)
