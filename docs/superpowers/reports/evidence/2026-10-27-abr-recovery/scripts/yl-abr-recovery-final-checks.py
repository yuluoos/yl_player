import subprocess,os,json,time
from pathlib import Path
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player')
out=Path('/private/tmp/yl-abr-recovery-20261027-checks');out.mkdir(exist_ok=False)
# Keep active playback isolated from the consolidated unit/analyzer work.
while True:
 try:
  if len(json.loads(Path('/private/tmp/yl-abr-recovery-20261027-native/results.json').read_text()))==2:break
 except (OSError,ValueError):pass
 time.sleep(5)
commands=[
 ('benchmark-tests',['python3','-B','-m','unittest','discover','-s','tool/playback_benchmark','-p','test_*.py'],root),
 ('example-tests',['/Users/yy2021_8689/flutter/bin/flutter','test','--no-pub','test','--reporter','expanded'],root/'packages/yl_player/example'),
 ('analyze',['/Users/yy2021_8689/flutter/bin/flutter','analyze','--no-pub'],root),
 ('format',['/Users/yy2021_8689/flutter/bin/dart','format','--output=none','--set-exit-if-changed','packages/yl_player/example/integration_test/abr_network_profile_test.dart','packages/yl_player/example/integration_test/support/abr_network_series.dart','packages/yl_player/example/test/abr_network_series_test.dart'],root),
 ('public-surface',['sh','tool/check_public_surface.sh'],root),
 ('source-parity',['python3','-B','tool/consumer_fixtures/apple_flutter/source_parity.py','--verify-identical'],root),
 ('thresholds',['python3','-B','tool/playback_benchmark/threshold_registry.py'],root),
 ('threshold-ready',['python3','-B','tool/playback_benchmark/threshold_registry.py','--require-ready'],root),
]
results=[]
for name,command,cwd in commands:
 print('START '+name,flush=True);start=time.monotonic()
 with (out/(name+'.log')).open('w') as log:
  try:code=subprocess.run(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,timeout=600).returncode
  except subprocess.TimeoutExpired:code=124
 results.append({'name':name,'command':command,'cwd':str(cwd),'exitCode':code,'seconds':round(time.monotonic()-start,3)})
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END '+name+' '+str(code),flush=True)
