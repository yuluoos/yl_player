from pathlib import Path
import json,hashlib,sys,subprocess
r=Path('/private/tmp/yl-loopback-error-source');old=Path('/private/tmp/yl-budget-low-cause')
source=json.loads((old/'source-identity.json').read_text());source={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in source}
(r/'source-identity.json').write_text(json.dumps(source,indent=2)+'\n')
sys.path.insert(0,'tool/release_readiness');import check
(r/'production-source.json').write_text(json.dumps(check.source_snapshot(Path.cwd()),indent=2)+'\n')
(r/'source.patch').write_bytes(subprocess.check_output(['git','diff']))
(r/'profiles.json').write_bytes((old/'profiles.json').read_bytes())
for name in ['offline.py','readiness.py','archive.py','replay-bytes.py','analyze.py','bytes.py','request-analysis.py','high-boundary.py']:
 s=(old/name).read_text().replace(str(old),str(r)).replace('2026-10-29-budget-low-cause','2026-10-29-loopback-error-source')
 if name in ['analyze.py','bytes.py','request-analysis.py','high-boundary.py']:
  s=s.replace("['budget-stall','budget-throttle','normal']","['budget-throttle','normal']")
 if name=='analyze.py':s=s.replace('boundaries,requests,6','boundaries,requests,7')
 (r/name).write_text(s)
s=(old/'run-media.py').read_text().replace(str(old),str(r)).replace("assert json.loads((Path('/private/tmp/yl-timeout-overflow')/'ios-final-result.json').read_text())['exitCode']==0","assert json.loads((r/'ios-final-result.json').read_text())['exitCode']==0")
s=s.replace("['budget-stall','budget-throttle','normal']","['budget-throttle','normal']")
(r/'run-media.py').write_text(s)
s=Path('/private/tmp/yl-timeout-overflow/bind-native.py').read_text().replace('/private/tmp/yl-timeout-overflow',str(r));(r/'bind-native.py').write_text(s)
print('frozen',len(source))
