import subprocess,json
from pathlib import Path
out=Path('/private/tmp/yl-public-policy')
cmd=json.loads(Path('docs/superpowers/reports/evidence/2026-10-28-ios-policy-intent/build-command.json').read_text())
cmd[cmd.index('-derivedDataPath')+1]='/private/tmp/yl-public-policy-ios'
(out/'build-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (out/'build.log').open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(out/'build-result.json').write_text(json.dumps({'exitCode':p.returncode})+'\n');print('build',p.returncode,flush=True)
raise SystemExit(p.returncode)
