from pathlib import Path
import json,sys,hashlib
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from bandwidth_diagnostics import summarize_requests
from network_profile import load_profiles
r=Path('/private/tmp/yl-original-bandwidth');profiles=load_profiles(r/'profiles.json');results={};binary=None
for name in ['original','zero-latency','headroom']:
 p=r/'media'/('reviewed-'+name)
 if not (p/'receipt.json').exists():continue
 d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');signals=a.read_rows(p/'signals.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');requests=a.read_rows(p/'requests.jsonl')
 if binary is None:binary=d['binaryHashes']
 assert binary==d['binaryHashes'] and d['binaryIdentityUnchanged'] and d['ownedProcessExited']
 errors=[];production=None
 try:production=a.summarize_production_recovery(rows,frames);a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal')
 except ValueError as e:errors.append(str(e))
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished']);assert continuity==d['continuityObservation']
 summary=a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']);assert summary==d['policyObservation']
 diag=summarize_requests(requests,profiles[requests[0]['profile']]);(r/(name+'-diagnostic.json')).write_text(json.dumps(dict(diag,policy=summary),indent=2)+'\n')
 published=[f for f in frames if f['frames']>0];phases=[]
 for f in published:
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(width=f['width'],elapsed=f['elapsed']))
 high=[];installed=[e for e in rows[-1]['automaticEvents'] if e['outcome']=='installed']
 if installed:
  index=next((i for i,f in enumerate(published) if f['elapsed']>installed[-1]['elapsedAfter'] and f['width']==640),None)
  if index is not None:high=published[index:]
 results[name]=dict(passed=d['passed'] and not errors and not signals,collectorPassed=d['passed'],nativeExitCode=d['exitCode'],strictErrors=errors,position=rows[-1]['position'],finalWidth=rows[-1]['width'],completed=rows[-1]['completed'],hostFailureCount=rows[-1]['hostFailureCount'],signals=signals,attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],publishedPhases=phases,production=production,continuity=continuity,stableHighAfterInstall=bool(high) and all(f['width']==640 for f in high),highTailSeconds=high[-1]['elapsed']-high[0]['elapsed'] if high else None,windows=[{k:x[k] for k in ['elapsed','reason','windowBitrate','windowRequests']} for x in policy if x['windowBitrate'] is not None],lastAccessLogs=rows[-1]['logs'])
initial=json.loads((r/'initial-source-identity.json').read_text());current=json.loads((r/'source-identity.json').read_text())
assert [k for k in initial if initial[k]!=current[k]]==['tool/playback_network/README.md']
changed = [k for k,h in current.items() if hashlib.sha256(Path(k).read_bytes()).hexdigest()!=h]
assert set(changed)=={'tool/playback_network/abr_accesslog.py','tool/playback_network/test_abr_policy.py'},changed
previous=json.loads(Path('/private/tmp/yl-resume-timeout/media/reviewed-original/receipt.json').read_text());assert previous['binaryHashes']==binary
out=dict(sameBinaryAsQualifiedBaseline=True,binaryHashes=binary,unchangedFrozenInputs=405,changedDocumentAndVerificationTools=['tool/playback_network/README.md',*changed],totalRuns=len(results),passedRuns=sum(x['passed'] for x in results.values()),results=results,capabilityAccepted=False,physicalOutputVerified=False,continuityAccepted=False)
(r/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for name,x in results.items():print(name,x['passed'],x['position'],x['attempts'],x['highTailSeconds'],x['continuity']['maximumPublishedFrameGapMs'])
