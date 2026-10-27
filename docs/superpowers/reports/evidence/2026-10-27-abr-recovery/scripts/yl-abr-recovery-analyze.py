import json,re,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'tool/playback_network'))
from summarize_capture import read_capture
root=Path('/private/tmp/yl-abr-recovery-20261027-runs')
rows=[]
for path in sorted(root.glob('*-auto*/summary.json')):
 result,samples=read_capture(path.with_name('capture.log'))
 summary=json.loads(path.read_text());changes=[];last=None
 for sample in samples:
  size=(sample['width'],sample['height'])
  if size[0] and size!=last:
   changes.append({k:sample.get(k) for k in ('elapsedUs','positionUs','bufferedPositionUs','width','height','estimatedBitrate','rebufferCount','droppedFrames')});last=size
 estimates=[s['estimatedBitrate'] for s in samples if s.get('estimatedBitrate') is not None]
 trace=[json.loads(s) for s in path.with_name('requests.jsonl').read_text().splitlines()]
 failures=[r for r in trace if r['outcome']!='complete' or r.get('status') not in (200,206)]
 full_buffer=next((s for s in samples if s.get('bufferedPositionUs',0)>=result['programmeDurationSeconds']*1000000),None)
 rows.append({'run':path.parent.name,'summary':summary,'geometryTransitions':changes,'publicEstimatedBitrate':{'min':min(estimates,default=None),'max':max(estimates,default=None),'last':estimates[-1] if estimates else None},'firstFullBufferSample':full_buffer,'requestFailures':failures})
(root/'trajectory-analysis.json').write_text(json.dumps(rows,indent=2)+'\n')
for row in rows:
 print(row['run'], row['summary']['adaptationObserved'],row['geometryTransitions'],row['publicEstimatedBitrate'])
