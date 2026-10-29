from pathlib import Path
import json,hashlib
root=Path('/private/tmp/yl-continuity-runs')
out=[]
for name,action,scenario in json.loads((root/'planned.json').read_text()):
 p=root/name
 if not (p/'receipt.json').exists():continue
 receipt=json.loads((p/'receipt.json').read_text())
 rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()]
 frames=[json.loads(x) for x in (p/'frame-samples.jsonl').read_text().splitlines()]
 transitions=[];last=None
 for r in frames:
  if r['frames'] and r['width']!=last:
   transitions.append(dict(elapsed=r['elapsed'],width=r['width'],generation=r['generation']));last=r['width']
 events=rows[-1]['automaticEvents']
 for e in events:
  e=dict(e)
  e['firstHighPublishedElapsed']=next((f['elapsed'] for f in frames if f['frames'] and f['width']==640 and f['elapsed']>e['elapsedAfter']),None) if e['outcome']=='installed' else None
  # Don't modify original final row/events.
 final_events=[dict(e,firstHighPublishedElapsed=next((f['elapsed'] for f in frames if f['frames'] and f['width']==640 and f['elapsed']>e['elapsedAfter']),None) if e['outcome']=='installed' else None) for e in events]
 out.append(dict(name=name,passed=receipt['passed'],binaryIdentityUnchanged=receipt['binaryIdentityUnchanged'],ownedProcessExited=receipt['ownedProcessExited'],events=final_events,frames=receipt.get('continuityObservation'),transitions=transitions,lastPosition=rows[-1]['position'],lastWidth=rows[-1]['width'],completed=rows[-1]['completed'],capabilityAccepted=False))
(root/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for r in out:
 print(r['name'],r['passed'],'lastWidth',r['lastWidth'],'events',[(e['attempt'],e['outcome'],round(e['elapsedAfter'],3),e['textureClearsAfter']-e['textureClearsBefore']) for e in r['events']],r['frames']['replacementBoundaries'])
