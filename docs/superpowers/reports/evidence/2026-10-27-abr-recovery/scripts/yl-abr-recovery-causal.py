import subprocess,json,time,hashlib
from pathlib import Path
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player');out=Path('/private/tmp/yl-abr-recovery-20261027-causal');out.mkdir(exist_ok=False)
files=['tool/playback_network/prepare_fixture.py','tool/playback_network/network_profile.py','tool/playback_network/abr_accesslog.py','tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift','packages/yl_player/example/ios/RunnerTests/YlDashResourceLoaderTests.swift']
(out/'source-identity.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},indent=2)+'\n')
results=[]
for name,direct,delay in [('managed-original-order',False,0),('direct-delayed',True,1000)]:
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-remaining-20261026-ios/Build/Products','--directory',str(out/name),'--device','B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8','--duration-seconds','120','--startup-delay-ms',str(delay)]
 if direct:cmd.append('--direct-hls-control')
 print('START '+name,flush=True);start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:code=subprocess.run(cmd,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=360).returncode
 results.append({'name':name,'command':cmd,'exitCode':code,'seconds':time.monotonic()-start})
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(code),flush=True)
