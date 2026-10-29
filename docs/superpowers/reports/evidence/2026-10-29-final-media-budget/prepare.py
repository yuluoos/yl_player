from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-final-media-budget');old=Path('/private/tmp/yl-timeout-overflow');half=Path('/private/tmp/yl-half-close-fix')
for name in ['source-identity.json','binary-identity.json','production-source.json']:
 (r/name).write_bytes((old/name).read_bytes())
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');actual={str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert actual==json.loads((r/'binary-identity.json').read_text())
assert json.loads((old/'ios-final-result.json').read_text())['exitCode']==0
(r/'profiles.json').write_bytes((half/'profiles.json').read_bytes())
for name in ['analyze.py','bytes.py','replay-bytes.py','readiness.py','archive.py']:
 s=(half/name).read_text().replace(str(half),str(r)).replace('2026-10-29-ios-half-close-fix','2026-10-29-final-media-budget')
 if name in ['analyze.py','bytes.py']:
  s=s.replace("['normal','original']","['normal','pause-resume','original']")
 if name=='analyze.py':
  s=s.replace("if not name.startswith('original') and len(installs)==2:","if name=='normal' and len(installs)==2:")
  s=s.replace("if not name.startswith('original') and proof is None:","if name=='normal' and proof is None:")
 if name=='archive.py':
  a=s.index("(out/'README.md').write_text(");b=s.index('\nfiles=sorted',a);s=s[:a]+"(out/'README.md').write_text('新制品长素材高档恢复、预算耗尽与连续性采集：原始请求/策略/帧、完整xcresult、失败及复审均保留。详见 ../../2026-10-29-final-media-budget.md。\\n')"+s[b:]
 (r/name).write_text(s)
s=(half/'run-media.py').read_text().replace(str(half),str(r))
s=s.replace("(r/'ios-fixed-result.json')","(Path('/private/tmp/yl-timeout-overflow')/'ios-final-result.json')")
s=s.replace("['normal','normal-repeat','normal-third','original']","['normal','pause-resume','original']")
s=s.replace("command='none'","command='pause-resume' if name=='pause-resume' else 'none'")
s=s.replace("if not name.startswith('original'):cmd.append('--require-production-install')","if not name.startswith('original'):cmd.append('--require-production-install')\n if name=='pause-resume':cmd.append('--require-budget-exhaustion')")
(r/'run-media.py').write_text(s)
(r/'reuse.json').write_text(json.dumps(dict(baseline=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),sourceIdentityMatches=True,binaryIdentityMatches=True,sourceFiles=len(json.loads((r/'source-identity.json').read_text())),binaryFiles=len(actual),nativeEvidence='docs/superpowers/reports/evidence/2026-10-29-native-timeout-overflow',iosSelected=254,macosSelected=229,newNativeMatrixRun=False),indent=2)+'\n')
print('source and binary match; reuse signed test product')
