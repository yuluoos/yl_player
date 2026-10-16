from pathlib import Path
import subprocess,json,hashlib,sys,os,time
root=Path('/private/tmp/yl-p07-metadata/yl_player');out=root/'docs/superpowers/reports/evidence/2026-10-16-p07-metadata';out.mkdir(parents=True,exist_ok=True)
media=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/sol-levante-p5-1080p.mp4')
parser=Path('/private/tmp/yl-p07-metadata/native-green/target/release/yl-dovi-stream-inspector')
commands={
 'python-tests':[sys.executable,'-B','-m','unittest','discover','-s','tool/dolby_reference','-p','test_*.py'],
 'inventory':[sys.executable,'-B','tool/dolby_reference/inventory.py'],
 'full-scan':[sys.executable,'-B','tool/dolby_reference/stream_inventory.py','--media',str(media),'--sha256','87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346','--inspector',str(parser),'--trace','/private/tmp/yl-p07-metadata/verified-trace.jsonl'],
}
name=sys.argv[1];log=out/(name+'.log');start=time.monotonic()
with log.open('w') as f:r=subprocess.run(commands[name],cwd=root,stdout=f,stderr=subprocess.STDOUT)
receipt={'command':commands[name],'cwd':str(root),'exit_code':r.returncode,'duration_seconds':round(time.monotonic()-start,3),'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()}
(out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt));print('\n'.join(log.read_text().splitlines()[-10:]));sys.exit(r.returncode)
