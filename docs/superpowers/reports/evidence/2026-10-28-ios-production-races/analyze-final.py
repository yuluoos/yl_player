from pathlib import Path
import json,hashlib,sys
sys.path.insert(0,'tool/playback_network');import abr_accesslog as a
r=Path('/private/tmp/yl-production-races');media=r/'media';names=['final-pause-prepared','final-seek-prepared','final-load-prepared','final-original','final-normal-1','final-normal-2','final-normal-3'];result={};binary=None
for n in names:
 p=media/n;d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');marker=rows[-1].get('productionCommandEvents',{})
 assert d['passed'] and not d['errors'] and d['binaryIdentityUnchanged'] and d['ownedProcessExited'],n
 if binary is None:binary=d['binaryHashes']
 else:assert d['binaryHashes']==binary,n
 assert rows[-1]['completed'] and rows[-1]['position']>=119.5 and rows[-1]['width']==640 and not a.read_rows(p/'signals.jsonl'),n
 production=a.summarize_production_recovery(rows,frames)
 command=a.summarize_production_race(rows,frames,d['policyObservation']) if n.endswith('-prepared') else None
 published=[f for f in frames if f['frames']>0];phases=[]
 for f in published:
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(width=f['width'],elapsed=f['elapsed']))
 final_low=max(i for i,f in enumerate(published) if f['width']==320);tail=published[final_low+1:]
 assert tail and all(f['width']==640 for f in tail),n
 if n.startswith('final-normal'):
  assert production['installed']==1 and rows[-1]['automaticAttempts']==1,n
  installed=rows[-1]['automaticEvents'][0]['elapsedAfter']
  recovered=next(i for i,f in enumerate(published) if f['elapsed']>installed and f['width']==640)
  assert all(f['width']==640 for f in published[recovered:]),n
  tail=published[recovered:]
 result[n]=dict(passed=True,finalPosition=rows[-1]['position'],attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],command=command,commandMarker=marker,production=production,continuity=d['continuityObservation'],profileSha256=d['profileSha256'],publishedPhases=phases,finalHighFrames=sum(f['frames'] for f in tail),finalHighSpanSeconds=tail[-1]['elapsed']-tail[0]['elapsed'],signals=0)
(r/'final-media-analysis.json').write_text(json.dumps(dict(sameBinary=True,binaryHashes=binary,normalRecoveryRuns=3,normalRecoveryPassed=3,results=result,capabilityAccepted=False,physicalOutputVerified=False,continuityAccepted=False),indent=2)+'\n');print('7 final controlled captures verified; three normal recoveries 3/3, no physical acceptance')
