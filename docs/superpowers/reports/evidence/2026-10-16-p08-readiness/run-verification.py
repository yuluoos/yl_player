from pathlib import Path
import json,sys,subprocess,time,hashlib
root=Path('/private/tmp/yl-p08-release/yl_player');out=root/'docs/superpowers/reports/evidence/2026-10-16-p08-readiness'
mode=sys.argv[1]
commands={
 'suite':[sys.executable,'-B','-m','unittest','discover','-s','tool/playback_benchmark','-p','test_*.py'],
 'inventory':[sys.executable,'-B','tool/release_readiness/check.py'],
 'gate':[sys.executable,'-B','tool/release_readiness/check.py','--require-ready']}
cmd=commands[mode];expected=1 if mode=='gate' else 0;start=time.monotonic()
result=subprocess.run(cmd,cwd=root,capture_output=True)
stdout=out/(mode+'.log' if mode=='suite' else mode+'.json');stdout.write_bytes(result.stdout)
stderr=out/(mode+'-stderr.log');stderr.write_bytes(result.stderr)
receipt=dict(command=cmd,cwd=str(root),exitCode=result.returncode,expectedExitCode=expected,durationSeconds=round(time.monotonic()-start,3),stdoutSha256=hashlib.sha256(result.stdout).hexdigest(),stderrSha256=hashlib.sha256(result.stderr).hexdigest())
(out/(mode+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
if mode=='suite':print('\n'.join(result.stderr.decode().splitlines()[-6:]))
else:print({k:v for k,v in json.loads(result.stdout).items() if k!='blockers'})
sys.exit(0 if result.returncode==expected else 2)
