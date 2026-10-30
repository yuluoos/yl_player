from pathlib import Path
import json,subprocess,hashlib,sys,time
r=Path('/private/tmp/yl-failure-observations');media=r/'media';media.mkdir(exist_ok=True);host=subprocess.check_output(['ipconfig','getifaddr','en0'],text=True).strip()
assert json.loads((r/'reuse-identity.json').read_text())['unchangedBinary']
results=json.loads((media/'results.json').read_text()) if (media/'results.json').exists() else []
for name in sys.argv[1:]:
 assert name in ['normal','normal-repeat','normal-third','original'];assert not (media/name).exists()
 for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
 command='none'
 profile='down-and-recover-v1' if name.startswith('original') else 'repeat-stall-budget-diagnostic-v1'
 cmd=['python3','-B','tool/playback_network/abr_accesslog.py','--products','/private/tmp/yl-production-exercise/ios-build/Build/Products','--directory',str(media/name),'--physical-device','00008140-000C49CC3493001C','--owned-host',host,'--duration-seconds','120','--profile',profile,'--recovery-action','auto-reload','--candidate-preparation','manifest-only','--auto-scenario','normal','--production-recovery','--production-command',command,'--profiles',str(r/'profiles.json'),'--connection-mode','close']
 if not name.startswith('original'):cmd.append('--require-production-install')
 (media/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n');print('start',name,flush=True);start=time.monotonic()
 with (media/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode,seconds=time.monotonic()-start));(media/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('end',name,p.returncode,flush=True)
 for kind in ['summary','tests']:
  q=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(media/(name+'.xcresult'))],capture_output=True,text=True);(media/(name+'-'+kind+'.json')).write_text(q.stdout)
 receipt=json.loads((media/name/'receipt.json').read_text())
 if not (media/name/'rows.jsonl').exists() or (media/name/'signals.jsonl').read_text().strip() or not receipt.get('ownedProcessExited'):break
