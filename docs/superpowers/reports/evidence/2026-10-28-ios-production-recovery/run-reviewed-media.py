from pathlib import Path
import json,subprocess,hashlib,sys,time,shutil
r=Path('/private/tmp/yl-production-recovery');mode=sys.argv[1]
if mode=='snapshot':
 names=set(json.loads(Path('/private/tmp/yl-postcommit-failure/source-identity.json').read_text()))
 names.update(str(p) for p in Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer').glob('YlDashAutoRecovery*.swift'))
 names.add('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlOpenCoordinator.swift')
 data={}
 for name in sorted(names):
  b=Path(name).read_bytes();p=r/'reviewed-source'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);data[name]=hashlib.sha256(b).hexdigest()
 (r/'reviewed-source-identity.json').write_text(json.dumps(data,indent=2)+'\n')
 shutil.copyfile('/private/tmp/yl-public-transport/latency-profiles.json',r/'latency-profiles.json');sys.exit()
if mode=='build':
 cmd=json.loads(Path('/private/tmp/yl-public-transport/review-build-command.json').read_text());(r/'build-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
 with (r/'build.log').open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 (r/'build-result.json').write_text(json.dumps(dict(exitCode=p.returncode))+'\n');print('build',p.returncode,flush=True);sys.exit(p.returncode)
results=[];media=r/'reviewed-media';media.mkdir(exist_ok=True)
for name,profile in [('original','down-and-recover-v1'),('zero-latency','stall-headroom-zero-latency-diagnostic-v1'),('pause-resume','stall-headroom-zero-latency-diagnostic-v1')]:
 for p,h in json.loads((r/'reviewed-source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-public-policy-ios/Build/Products','--directory',str(media/name),'--physical-device','00008140-000C49CC3493001C','--owned-host','192.168.50.196','--duration-seconds','120','--profile',profile,'--recovery-action','auto-reload','--candidate-preparation','manifest-only','--auto-scenario','normal','--production-recovery']
 if name=='pause-resume':cmd+=['--production-command','pause-resume']
 if name!='original':cmd+=['--profiles',str(r/'latency-profiles.json')]
 (media/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n');print('start',name,flush=True);start=time.monotonic()
 with (media/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode,seconds=time.monotonic()-start));(media/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('end',name,p.returncode,flush=True)
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(media/(name+'.xcresult'))],capture_output=True,text=True);(media/(name+'-'+kind+'.json')).write_text(q.stdout)
