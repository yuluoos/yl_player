from pathlib import Path
import json,sys,copy
r=Path('/private/tmp/yl-abr-main-merge');base=json.loads((r/'base-inventory.json').read_text());main=json.loads((r/'main-inventory.json').read_text());abr=json.loads((r/'abr-inventory.json').read_text());out=copy.deepcopy(main);mapping=[]
for k,v in abr['evidence'].items():
 assert k not in out['evidence'] or out['evidence'][k]==v
 out['evidence'][k]=v
for b,m,a,o in zip(base['rows'],main['rows'],abr['rows'],out['rows']):
 assert (b['requirement'],b['platform'])==(m['requirement'],m['platform'])==(a['requirement'],a['platform'])
 for k in ['implementation','verification','acceptance']:
  assert m[k]==a[k],(m['requirement'],k)
 refs=list(dict.fromkeys(m['evidence']+a['evidence']))
 o['evidence']=refs
 if a['nextAction']!=b['nextAction']:
  if m['nextAction']!=b['nextAction'] and a['nextAction']!=m['nextAction']:
   assert (m['requirement'],m['platform'])==('CAP-ABR','android')
   o['nextAction']='qualify-physical-api24-repeat-auto-caps-fixed-and-bound-output-after-local-120s-recovery'
  else:o['nextAction']=a['nextAction']
 mapping.append(dict(requirement=m['requirement'],platform=m['platform'],mainEvidence=m['evidence'],abrEvidence=a['evidence'],mergedEvidence=refs,mainNext=m['nextAction'],abrNext=a['nextAction'],mergedNext=o['nextAction']))
# The merge report links the full union for rows exceeding the existing bound.
for o in out['rows']:
 if len(o['evidence'])>20:o['evidence']=o['evidence'][-19:]+['abr-main-merge-20261029']
sys.path.insert(0,'tool/release_readiness');import check
out['source']=check.source_snapshot(Path.cwd())
# Added with the final report after checks; write only a temporary mapping now.
(r/'resolved-inventory.json').write_text(json.dumps(out,indent=2)+'\n');(r/'ledger-merge-map.json').write_text(json.dumps(mapping,indent=2)+'\n')
print('source',out['source']['sha256'],'evidence',len(out['evidence']))
