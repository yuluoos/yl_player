from pathlib import Path
import json,copy
r=Path('/private/tmp/yl-reset-retry-control');d=json.loads((r/'profiles.json').read_text());late=[]
for original,ident in [('repeat-throttle-budget-diagnostic-v1','repeat-late-throttle-budget-diagnostic-v1'),('repeat-mild-budget-diagnostic-v1','repeat-late-mild-budget-diagnostic-v1')]:
 p=copy.deepcopy(next(v for v in d['profiles'] if v['id']==original));p['id']=ident;p['steps'][3]['atMs']=70000;p['steps'][4]['atMs']=75000;late.append(p)
(r/'late-profiles.json').write_text(json.dumps(dict(schemaVersion=1,profiles=late),indent=2)+'\n')
(r/'late-profile-delta.json').write_text(json.dumps(dict(reason='original 50k run had no high output before second impairment; retained as failed budget exercise',bothSecondPhasesShiftedFrom=[60000,65000],bothSecondPhasesShiftedTo=[70000,75000],onlyDifferenceBetweenNewPair='step3.bytesPerSecond 50000 vs 75000 plus descriptive profile id',noThresholdOrBudgetChange=True),indent=2)+'\n')
s=(r/'run-media.py').read_text().replace("['budget-throttle','budget-mild','normal']","['budget-late-throttle','budget-late-mild']").replace("{'budget-throttle':'repeat-throttle-budget-diagnostic-v1','budget-mild':'repeat-mild-budget-diagnostic-v1','normal':'repeat-stall-budget-diagnostic-v1'}","{'budget-late-throttle':'repeat-late-throttle-budget-diagnostic-v1','budget-late-mild':'repeat-late-mild-budget-diagnostic-v1'}").replace("r/'profiles.json'","r/'late-profiles.json'")
(r/'run-media-late.py').write_text(s)
for n in ['analyze.py','bytes.py','request-analysis.py','high-boundary.py','error-analysis.py','retry-analysis.py','access-analysis.py']:
 p=r/n;s=p.read_text().replace("['budget-throttle','budget-mild','normal']","['budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild']").replace("('budget-throttle','budget-mild','normal')","('budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild')")
 if n=='request-analysis.py':
  s=s.replace("for low,high in [(0,60000),(60000,65000),(65000,90000),(90000,None)]:","impairment=70000 if 'late-' in label else 60000; recovery=impairment+5000\n for low,high in [(0,impairment),(impairment,recovery),(recovery,90000),(90000,None)]:")
  s=s.replace("results[label]=dict(postInstallOutput=proof", "results[label]=dict(impairmentProfileMs=impairment,recoveryProfileMs=recovery,postInstallOutput=proof").replace("'highRequestsAfter65'","'highRequestsAfterRecovery'")
 if n=='high-boundary.py':s=s.replace("59000<=s['startMs']<66000","(69000 if 'late-' in n else 59000)<=s['startMs']<(76000 if 'late-' in n else 66000)")
 if n=='retry-analysis.py':s=s.replace("s['startMs']>=60000","s['startMs']>=(70000 if 'late-' in n else 60000)")
 p.write_text(s)
p=Path('docs/superpowers/plans/2026-10-29-reset-retry-control.md');s=p.read_text()+'\n补充：首50k预算轮最终640但未在第二降速前恢复高档，未形成再次降档，严格失败保留；温和75k轮高档保持、无第二阶段错误，也缺再次降档。用户另授权约6分钟；新增统一70–75秒故障的50k/75k两轮，独立profile，不覆盖原三轮。\n';p.write_text(s)
