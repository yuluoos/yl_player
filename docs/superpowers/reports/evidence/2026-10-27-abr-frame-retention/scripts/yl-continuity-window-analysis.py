"""Post-hoc estimates from main rows, not exact internal policy samples."""
import json
from pathlib import Path
root=Path('/private/tmp/yl-continuity-physical-retry');results=[]
for name,_,_ in json.loads((root/'planned.json').read_text()):
 path=root/name/'rows.jsonl'
 if not path.exists():continue
 rows=[json.loads(x) for x in path.read_text().splitlines()];windows=[];saw=False;anchor=None;eligible_high=0
 for r in rows:
  position=r['position'];end=position
  for item in sorted(r['loadedRanges'],key=lambda item:item['start']):
   if item['start']+item['duration']<position:continue
   if item['start']>end:break
   end=max(end,item['start']+item['duration'])
  ok=r['status']==1 and r['rate']>0 and r['likelyToKeepUp'] and end-position>=5 and 120-position>=20
  if not ok:anchor=None;continue
  if r['width']==640:saw=True;eligible_high+=1;anchor=None;continue
  if not saw or r['width']!=320 or sum(x['downloadOverdue'] for x in r['logs'])<=0:anchor=None;continue
  sample=(r['elapsed'],position,sum(x['bytes'] for x in r['logs']),sum(x['transferDuration'] for x in r['logs']),sum(x['requests'] for x in r['logs']))
  if anchor is None:anchor=sample;continue
  if any(sample[i]<anchor[i] for i in [2,3,4]):anchor=sample;continue
  if sample[0]-anchor[0]<8:continue
  duration=sample[3]-anchor[3];bitrate=(sample[2]-anchor[2])*8/duration if duration>0 else 0
  windows.append(dict(start=anchor[0],end=sample[0],bitrate=bitrate,requests=sample[4]-anchor[4],meetsBitrate=bitrate>=955000));anchor=sample
 results.append(dict(name=name,eligibleHighRowCount=eligible_high,estimatedWindows=windows,actualRecordedAttempts=rows[-1]['automaticAttempts']))
(root/'estimated-windows.json').write_text(json.dumps(dict(method='Post-hoc main-row sampling; not exact policy decisions or available bandwidth proof',thresholdUnchanged=955000,runs=results),indent=2)+'\n')
