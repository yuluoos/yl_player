from pathlib import Path
import json,sys,hashlib
sys.path.insert(0,'tool/playback_network');import abr_accesslog as a
r=Path('/private/tmp/yl-resume-timeout');names=['reviewed-original','reviewed-normal-1','reviewed-normal-2','reviewed-normal-3','reviewed-pause-prepared','reviewed-seek-prepared','reviewed-load-prepared'];result={};binary=None
for name in names:
 p=r/'media'/name;d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');signals=a.read_rows(p/'signals.jsonl')
 if binary is None:binary=d['binaryHashes']
 assert d['binaryHashes']==binary and d['binaryIdentityUnchanged'] and d['ownedProcessExited'],name
 errors=[];production=None;command=None
 try:
  production=a.summarize_production_recovery(rows,frames)
  if name.endswith('-prepared'):command=a.summarize_production_race(rows,frames,d['policyObservation'])
  a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal')
 except ValueError as e:errors.append(str(e))
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished']);assert continuity==d['continuityObservation']
 published=[f for f in frames if f['frames']>0];phases=[]
 for f in published:
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(width=f['width'],elapsed=f['elapsed']))
 highTail=[];stable=None
 if name.startswith('reviewed-normal') and production and production['installed']==1:
  event=next(e for e in rows[-1]['automaticEvents'] if e['outcome']=='installed')
  index=next((i for i,f in enumerate(published) if f['elapsed']>event['elapsedAfter'] and f['width']==640),None)
  if index is not None:highTail=published[index:];stable=all(f['width']==640 for f in highTail)
 conditions=dict(nativePassed=d['exitCode']==0,collectorPassed=d['passed'],strictReassessmentPassed=not errors,completed=rows[-1]['completed'] and rows[-1]['position']>=119.5,finalHigh=rows[-1]['width']==640,noSignals=not signals)
 if name.startswith('reviewed-normal'):conditions.update(exactlyOneInstall=bool(production and production['installed']==1 and rows[-1]['automaticAttempts']==1),stableHighToEnd=stable is True)
 result[name]=dict(passed=all(conditions.values()),conditions=conditions,strictErrors=errors,finalPosition=rows[-1]['position'],attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],publishedPhases=phases,production=production,command=command,commandMarker=rows[-1].get('productionCommandEvents',{}),continuity=continuity,finalHighSpanSeconds=highTail[-1]['elapsed']-highTail[0]['elapsed'] if highTail else None)
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
summary=dict(sameBinary=True,binaryHashes=binary,totalRuns=len(names),passedRuns=sum(x['passed'] for x in result.values()),normalRecoveryRuns=3,normalRecoveryPassed=sum(result[n]['passed'] for n in names if n.startswith('reviewed-normal')),results=result,capabilityAccepted=False,physicalOutputVerified=False,continuityAccepted=False)
(r/'media-analysis.json').write_text(json.dumps(summary,indent=2)+'\n');print({k:v for k,v in summary.items() if k not in ['binaryHashes','results']})
for n,x in result.items():print(n,x['passed'],x['finalPosition'],x['attempts'],x['finalHighSpanSeconds'],x['continuity']['maximumPublishedFrameGapMs'])
