from pathlib import Path
import json
root=Path('/private/tmp/yl-auto-20261027');out=[]
for p in sorted(root.iterdir()):
 if not (p/'receipt.json').exists():continue
 d=json.loads((p/'receipt.json').read_text()); rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()];frames=[json.loads(x) for x in (p/'frame-samples.jsonl').read_text().splitlines()];pub=[f for f in frames if f['frames']]
 events=rows[-1]['automaticEvents']; transitions=[]
 for a,b in zip(pub,pub[1:]):
  if a['generation']!=b['generation']:transitions.append({'old':a,'new':b,'gapMs':(b['elapsed']-a['elapsed'])*1000,'positionDelta':b['position']-a['position']})
 for e in events:
  after=[f for f in pub if e['outcome']=='installed' and f['elapsed']>=e['elapsedAfter'] and f['width']==640]
  e['firstHighFrameElapsed']=after[0]['elapsed'] if after else None
 ranges_at_actions=[]
 for e in events:
  r=min(rows,key=lambda r:abs(r['elapsed']-e['elapsed']))
  ranges_at_actions.append({'elapsed':r['elapsed'],'position':r['position'],'loadedRanges':r['loadedRanges']})
 logs=root/(p.name+'-system-log.json');logs=json.loads(logs.read_text()) if logs.exists() else []
 out.append({'name':p.name,'passed':d['passed'],'errors':d['errors'],'observation':d.get('observation'),'continuity':d.get('continuityObservation'),'finalPosition':rows[-1]['position'],'attempts':rows[-1]['automaticAttempts'],'events':events,'frameTransitions':transitions,'rangesAtActions':ranges_at_actions,'penaltyEvents':[l['eventMessage'] for l in logs if 'MoveAlternateToPenaltyBox' in l.get('eventMessage','')]})
(root/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for d in out:print(d['name'],d['attempts'],d['events'],d['continuity'], 'transitions',[(x['gapMs'],x['positionDelta']) for x in d['frameTransitions']])
