from pathlib import Path
import subprocess,json,hashlib,time
root=Path('/private/tmp/yl-public-race');media=root/'media';media.mkdir(exist_ok=True)
identity=json.loads((root/'source-identity.json').read_text())
for p,h in identity.items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
results=[]
for name,profile,scenario in [('caps','stall-headroom-zero-latency-diagnostic-v1','caps-during-preparation'),('fixed','stall-headroom-zero-latency-diagnostic-v1','fixed-during-preparation'),('original','down-and-recover-v1','caps-during-preparation')]:
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-public-policy-ios/Build/Products','--directory',str(media/name),'--physical-device','00008140-000C49CC3493001C','--owned-host','192.168.1.20','--duration-seconds','120','--profile',profile,'--public-policy-race','--recovery-action','auto-reload','--candidate-preparation','asset-preroll','--auto-scenario',scenario]
 if name!='original':cmd+=['--profiles',str(root/'latency-profiles.json')]
 (media/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
 print('start',name,flush=True);start=time.monotonic()
 with (media/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode,seconds=time.monotonic()-start))
 (media/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('finished',name,p.returncode,flush=True)
 for key,command in [('summary',['xcrun','xcresulttool','get','test-results','summary','--path']),('tests',['xcrun','xcresulttool','get','test-results','tests','--path'])]:
  result=subprocess.run(command+[str(media/name)+'.xcresult'],capture_output=True,text=True)
  (media/(name+'-'+key+'.json')).write_text(result.stdout)
