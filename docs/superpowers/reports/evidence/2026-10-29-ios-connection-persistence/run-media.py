from pathlib import Path
import json,subprocess,hashlib,sys,time
r=Path('/private/tmp/yl-connection-persistence');media=r/'media';media.mkdir(exist_ok=True);host=subprocess.check_output(['ipconfig','getifaddr','en0'],text=True).strip()
results=json.loads((media/'results.json').read_text()) if (media/'results.json').exists() else []
for mode in sys.argv[1:]:
 assert mode in ['close','http11-close','http11-keepalive'];assert not (media/mode).exists()
 for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-recovery-landing/ios-build/Build/Products','--directory',str(media/mode),'--physical-device','00008140-000C49CC3493001C','--owned-host',host,'--duration-seconds','120','--profile','down-and-recover-v1','--recovery-action','auto-reload','--candidate-preparation','manifest-only','--auto-scenario','normal','--production-recovery','--profiles',str(r/'profiles.json'),'--connection-mode',mode]
 (media/(mode+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n');print('start',mode,flush=True);start=time.monotonic()
 with (media/(mode+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=mode,command=cmd,exitCode=p.returncode,seconds=time.monotonic()-start));(media/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('end',mode,p.returncode,flush=True)
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(media/(mode+'.xcresult'))],capture_output=True,text=True);(media/(mode+'-'+kind+'.json')).write_text(q.stdout)
 receipt=json.loads((media/mode/'receipt.json').read_text())
 if receipt['exitCode'] != 0:break
