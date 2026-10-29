from pathlib import Path
import json,re,hashlib
root=Path('/private/tmp/yl-local-acceptance')
results=[]
for d in sorted(root.glob('local-*')):
 if not d.is_dir() or not (d/'summary.json').exists():continue
 summary=json.loads((d/'summary.json').read_text())
 raw=(d/'capture.log').read_text()
 samples=[json.loads(x) for x in re.findall(r'YL_ABR_SAMPLE=(\{[^\r\n]*\})',raw)]
 geom=[]
 for s in samples:
  g=[s.get('width'),s.get('height')]
  if None not in g and (not geom or geom[-1]!=g):geom.append(g)
 rows=[json.loads(x) for x in (d/'requests.jsonl').read_text().splitlines()]
 media=[x for x in rows if '/chunk-' in x.get('asset','') and x.get('bodyBytesWritten',0)>0]
 results.append(dict(runId=summary['runId'],summary=summary,geometry=geom,
  finalPositionUs=samples[-1]['positionUs'] if samples else None,
  lastMediaWriteMs=max((r['endMs'] for r in media),default=None),
  process=json.loads((d/'result.json').read_text())))
(root/'abr-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
for r in results:print(r['runId'],r['geometry'],r['finalPositionUs'],r['summary']['adaptationObserved'],r['summary']['networkPhasesCovered'])
