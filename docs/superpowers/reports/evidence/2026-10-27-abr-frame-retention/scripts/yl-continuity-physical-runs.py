from pathlib import Path
import subprocess,json,time,hashlib
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player')
out=Path('/private/tmp/yl-continuity-physical-runs'); out.mkdir(exist_ok=False)
planned=[('baseline','none','normal'),('auto','auto-reload','normal'),('auto-repeat','auto-reload','normal'),('auto-pause','auto-reload','pause-first')]
(out/'planned.json').write_text(json.dumps(planned,indent=2)+'\n')
files=['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift','tool/playback_network/abr_accesslog.py','tool/playback_network/abr_device.py','tool/playback_network/network_profile.py','tool/playback_network/prepare_fixture.py','tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift','packages/yl_player/example/ios/RunnerTests/YlDashResourceLoaderTests.swift']
(out/'source-identity.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},indent=2)+'\n')
results=[]
for name,action,scenario in planned:
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-continuity-device-build/Build/Products','--directory',str(out/name),'--physical-device','00008140-000C49CC3493001C','--owned-host','192.168.50.196','--duration-seconds','120','--recovery-action',action,'--auto-scenario',scenario]
 print('START',name,flush=True);start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:code=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=360).returncode
 results.append(dict(name=name,command=cmd,exitCode=code,seconds=time.monotonic()-start));(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END',name,code,flush=True)

 if code != 0: break # Preserve failure and investigate before dependent captures.
