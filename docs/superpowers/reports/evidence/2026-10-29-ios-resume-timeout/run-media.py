from pathlib import Path
import json,subprocess,hashlib,sys,time,shutil
r=Path('/private/tmp/yl-resume-timeout');mode=sys.argv[1]
media=r/'media';media.mkdir(exist_ok=True);resultfile=media/'results.json';results=json.loads(resultfile.read_text()) if resultfile.exists() else []
names=['reviewed-original','reviewed-normal-1','reviewed-normal-2','reviewed-normal-3','reviewed-pause-prepared','reviewed-seek-prepared','reviewed-load-prepared'] if mode=='all' else sys.argv[1:]
host=subprocess.check_output(['ipconfig','getifaddr','en0'],text=True).strip()
for name in names:
 assert not (media/name).exists(),name
 for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
 scenario=name.removeprefix('reviewed-').removeprefix('final-')
 profile='down-and-recover-v1' if scenario=='original' else 'stall-headroom-zero-latency-diagnostic-v1'
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-recovery-landing/ios-build/Build/Products','--directory',str(media/name),'--physical-device','00008140-000C49CC3493001C','--owned-host',host,'--duration-seconds','120','--profile',profile,'--recovery-action','auto-reload','--candidate-preparation','manifest-only','--auto-scenario','normal','--production-recovery']
 if scenario.endswith('-prepared'):cmd+=['--production-command',scenario]
 if scenario!='original':cmd+=['--profiles',str(r/'latency-profiles.json')]
 (media/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n');print('start',name,flush=True);start=time.monotonic()
 with (media/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode,seconds=time.monotonic()-start));resultfile.write_text(json.dumps(results,indent=2)+'\n');print('end',name,p.returncode,flush=True)
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(media/(name+'.xcresult'))],capture_output=True,text=True);(media/(name+'-'+kind+'.json')).write_text(q.stdout)
 if p.returncode:sys.exit(p.returncode)
