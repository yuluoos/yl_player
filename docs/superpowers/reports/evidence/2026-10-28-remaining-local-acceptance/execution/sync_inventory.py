from pathlib import Path
import importlib.util,json,hashlib
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player');spec=importlib.util.spec_from_file_location('readiness',root/'tool/release_readiness/check.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
p=root/'tool/release_readiness/inventory.json';v=json.loads(p.read_text());v['source']=m.source_snapshot(root)
key='remaining-local-acceptance-20261028';report='docs/superpowers/reports/2026-10-28-remaining-local-acceptance.md'
v['evidence'][key]=dict(path=report,sha256=hashlib.sha256((root/report).read_bytes()).hexdigest(),kind='report')
for r in v['rows']:
 if key not in r['evidence']:r['evidence'].append(key)
 if r['requirement']=='CAP-ABR' and r['platform']=='android':r['nextAction']='complete-physical-api24-repeat-and-bound-output-qualification-after-120s-local-recovery-observed'
p.write_text(json.dumps(v,indent=2)+'\n')
print(v['source']['sha256'])
