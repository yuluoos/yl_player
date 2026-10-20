from pathlib import Path
import hashlib,json,shutil,subprocess,time,sys
root=Path('/Users/yy2021_8689/.codex/worktrees/p02-tracks-subtitles/yl_player')
out=root/'.superpowers/sdd/2026-10-20-p02-device-completion/logs'/('iphone-'+time.strftime('%Y%m%d-%H%M%S'))
out.mkdir()
proxy=Path('/Users/yy2021_8689/flutter/bin/cache/artifacts/libusbmuxd/iproxy')
backup=Path('/private/tmp/p04-iproxy-original-x86_64')
expected='e90e52022d917852d7b48bc7ff123b4a1ded3a4d8692e85c9ad0adca8bf78865'
wrapper='#!/bin/sh\nunset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH\nexec /opt/homebrew/bin/iproxy "$@"\n'
assert hashlib.sha256(proxy.read_bytes()).hexdigest()==expected
assert hashlib.sha256(backup.read_bytes()).hexdigest()==expected
target=sys.argv[2] if len(sys.argv)>2 else 'integration_test/p02_iphone_acceptance_test.dart'
cmd=['/Users/yy2021_8689/flutter/bin/flutter','test','--no-pub','--no-uninstall',target,'-d','00008140-000C49CC3493001C','--reporter','expanded']
if len(sys.argv)>1:cmd+=['--name',sys.argv[1]]
(out/'command.json').write_text(json.dumps(cmd))
files=list((root/'packages/yl_player/example/integration_test').rglob('*.dart'))+[root/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift',root/'packages/yl_player/example/ios/Runner/AppDelegate.swift',root/'tool/dash_timeline/capture_composition.py']
(out/'source-hashes.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
print('P02_CAPTURE='+str(out),flush=True)
helper=None
try:
 helper=subprocess.Popen(['/opt/homebrew/bin/python3',str(root/'tool/dash_timeline/capture_composition.py'),'--platform','ios-device','--device','00008140-000C49CC3493001C','--bind-address','192.168.50.196','--output',str(out/'pixels')],stdout=subprocess.PIPE,stderr=(out/'helper-errors.log').open('w'),text=True)
 first=helper.stdout.readline()
 url=json.loads(first)['captureUrl']
 (out/'helper-start.json').write_text(first)
 cmd+=['--dart-define=P01_CAPTURE_URL='+url,'--dart-define=P01_CAPTURE_HOST=192.168.50.196']
 (out/'command.json').write_text(json.dumps(cmd))
 proxy.write_text(wrapper)
 with (out/'capture.log').open('w') as log:
  child=subprocess.Popen(cmd,cwd=root/'packages/yl_player/example',stdout=log,stderr=subprocess.STDOUT)
  try: code=child.wait(timeout=900)
  except subprocess.TimeoutExpired:
   child.terminate()
   try: child.wait(timeout=10)
   except subprocess.TimeoutExpired:child.kill();child.wait()
   code=124
 (out/'exit-code').write_text(str(code))
 print('P02_EXIT='+str(code),flush=True)
finally:
 if helper:
  helper.terminate();output,_=helper.communicate(timeout=10)
  (out/'helper.log').write_text(output)
 assert proxy.read_text()==wrapper
 shutil.copy2(backup,proxy)
 restored=hashlib.sha256(proxy.read_bytes()).hexdigest()==expected
 (out/'cleanup.json').write_text(json.dumps({'iproxyRestored':restored,'captureHelperStopped':helper is None or helper.poll() is not None}))
 print('P02_CLEANUP='+str(restored),flush=True)
sys.exit(code)
