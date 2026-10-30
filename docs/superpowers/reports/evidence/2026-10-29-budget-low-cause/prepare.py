from pathlib import Path
import json,hashlib,subprocess,copy
r=Path('/private/tmp/yl-budget-low-cause');old=Path('/private/tmp/yl-final-media-budget')
for n in ['source-identity.json','binary-identity.json','production-source.json','reuse.json']:(r/n).write_bytes((old/n).read_bytes())
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');actual={str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert actual==json.loads((r/'binary-identity.json').read_text())
d=json.loads((r/'reuse.json').read_text());d['baseline']=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();(r/'reuse.json').write_text(json.dumps(d,indent=2)+'\n')
oldprofiles=json.loads((old/'profiles.json').read_text());base=next(p for p in oldprofiles['profiles'] if p['id']=='repeat-stall-budget-diagnostic-v1');control=copy.deepcopy(base);control['id']='repeat-throttle-budget-diagnostic-v1';assert control['steps'][3]==dict(atMs=60000,bytesPerSecond=0,latencyMs=0);control['steps'][3]['bytesPerSecond']=50000
(r/'profiles.json').write_text(json.dumps(dict(schemaVersion=1,profiles=[base,control]),indent=2)+'\n')
(r/'profile-delta.json').write_text(json.dumps(dict(baselineProfile=base['id'],controlProfile=control['id'],onlyStepDelta=dict(index=3,field='bytesPerSecond',before=0,after=50000),allOtherStepsEqual=all(a==b for i,(a,b) in enumerate(zip(base['steps'],control['steps'])) if i!=3),sameBudget=2,diagnosticControl=True,acceptanceThresholdsUnchanged=True),indent=2)+'\n')
for name in ['analyze.py','bytes.py','replay-bytes.py','readiness.py','archive.py','offline.py']:
 s=(old/name).read_text().replace(str(old),str(r)).replace('2026-10-29-final-media-budget','2026-10-29-budget-low-cause')
 if name in ['analyze.py','bytes.py']:s=s.replace("['normal','pause-resume','original']","['budget-stall','budget-throttle','normal']")
 if name=='analyze.py':s=s.replace("if name=='pause-resume':","if name.startswith('budget-'):")
 if name=='archive.py':
  a=s.index("(out/'README.md').write_text(");b=s.index('\nfiles=sorted',a);s=s[:a]+"(out/'README.md').write_text('预算耗尽低档原因单变量真机对照：原始失败、策略/请求/帧及完整xcresult、同制品绑定和复审。详见 ../../2026-10-29-budget-low-cause.md。\\n')"+s[b:]
 (r/name).write_text(s)
s=(old/'run-media.py').read_text().replace(str(old),str(r)).replace("['normal','pause-resume','original']","['budget-stall','budget-throttle','normal']")
s=s.replace("command='pause-resume' if name=='pause-resume' else 'none'","command='pause-resume' if name.startswith('budget-') else 'none'")
s=s.replace("profile='down-and-recover-v1' if name.startswith('original') else 'repeat-stall-budget-diagnostic-v1'","profile='repeat-throttle-budget-diagnostic-v1' if name=='budget-throttle' else 'repeat-stall-budget-diagnostic-v1'")
s=s.replace("if name=='pause-resume':cmd.append('--require-budget-exhaustion')","if name.startswith('budget-'):cmd.append('--require-budget-exhaustion')")
(r/'run-media.py').write_text(s)
print('frozen sources/products match; only second impairment throughput differs')
