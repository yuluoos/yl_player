from pathlib import Path
import json,sys,hashlib,copy
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from proxy_boundaries import record_proxy_observation
from network_profile import summarize_connections,load_profiles
from server_timing import summarize_server_timing
r=Path('/private/tmp/yl-production-exercise');results={};binary=json.loads((r/'binary-identity.json').read_text());profile=load_profiles(r/'profiles.json')['stall-headroom-zero-latency-diagnostic-v1']
for name in ['normal','pause-resume','pause-prepared','seek-prepared','load-prepared','pause-prepared-repeat']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');signals=a.read_rows(p/'signals.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');requests=a.read_rows(p/'requests.jsonl');boundaries=a.read_rows(p/'proxy-requests.jsonl')
 assert d['binaryHashes']==binary and d['binaryIdentityUnchanged'] and d['ownedProcessExited'] and d['profileSha256']==profile.sha256
 errors=[];checks={}
 def check(key,fn):
  try:checks[key]=fn();return checks[key]
  except (ValueError,KeyError,TypeError) as e:errors.append(dict(check=key,error=str(e)));return None
 check('policyVersion',lambda:a.policy_trace_version(rows));assert checks['policyVersion']==2
 sessions=a.production_sessions(rows)
 if len(sessions)==2:
  summaries={}
  for i,session in enumerate(sessions):
   selected=[dict(v) for v in rows if v['sessionId']==session]
   if i==0:selected[-1]['automaticEvents']=rows[-1]['productionCommandEvents']['oldEvents'];selected[-1]['automaticAttempts']=1
   summaries[session]=a.summarize_policy([v for v in policy if v['sessionId']==session],expected_attempts=selected[-1]['automaticAttempts']);a.validate_recovery_authority(selected,summaries[session])
  checks['policy']={'sessions':summaries,'capabilityAccepted':False}
 else:
  check('policy',lambda:a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']))
  check('authority',lambda:a.validate_recovery_authority(rows,checks['policy']))
 if 'policyObservation' in d:assert checks['policy']==d['policyObservation']
 else:errors.append(dict(check='originalReceipt',error='policy observation absent'))
 check('production',lambda:a.summarize_production_recovery(rows,frames,require_install=name!='load-prepared'))
 if name=='pause-resume':check('command',lambda:a.summarize_production_command(rows,checks['policy']))
 elif name.removesuffix('-repeat').endswith('-prepared'):check('command',lambda:a.summarize_production_race(rows,frames,checks['policy']))
 check('playback',lambda:a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal'))
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished'])
 if 'continuityObservation' in d:assert continuity==d['continuityObservation']
 reassessment={'errors':[]}
 try:record_proxy_observation(reassessment,boundaries,requests,2)
 except (ValueError,KeyError,TypeError) as e:reassessment['errors'].append(str(e))
 proxy=reassessment.get('proxyRequestObservation',{})
 errors.extend(dict(check='proxy',error=x) for x in reassessment['errors'])
 connections=summarize_connections(requests,'close');assert connections==d['connectionObservation']
 timing=summarize_server_timing(requests);assert timing==d['serverTimingObservation']
 if signals:errors.append(dict(check='signals',error='capture interrupted'))
 if d['exitCode']!=0:errors.append(dict(check='native',error=str(d['exitCode'])))
 assert d['productionInstallRequired']==(name!='load-prepared')
 if checks.get('production') is not None and 'productionRecoveryObservation' in d:assert checks['production']==d['productionRecoveryObservation']
 if checks.get('command') is not None and 'productionCommandObservation' in d:assert checks['command']==d['productionCommandObservation']
 published=[f for f in frames if f['frames']>0];phases=[];high=False;low=False;recover=None
 for i,f in enumerate(published):
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(width=f['width'],elapsed=f['elapsed']))
  if f['width']==640:
   if low and recover is None:recover=i
   high=True
  elif f['width']==320 and high:low=True
 tail=published[recover:] if recover is not None else []
 reservations=[v for v in policy if v['reason']=='reserved'];tickets=[v for v in policy if v['reason']=='ticketReady']
 results[name]=dict(originalReceiptPassed=d['passed'],nativeExitCode=d['exitCode'],reassessmentPassed=not errors,errors=errors,position=rows[-1]['position'],completed=rows[-1]['completed'],finalWidth=rows[-1]['width'],attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],commandEvents=rows[-1].get('productionCommandEvents'),hostFailureCount=rows[-1]['hostFailureCount'],signals=signals,policy=checks['policy'],policySamplingVersion=checks['policyVersion'],production=checks.get('production'),command=checks.get('command'),reservations=reservations,tickets=tickets,publishedPhases=phases,highTailSeconds=tail[-1]['elapsed']-tail[0]['elapsed'] if tail else None,stableHighAfterRecovery=bool(tail) and all(f['width']==640 for f in tail),continuity=continuity,proxySummary={k:v for k,v in proxy.items() if k!='requests'},serverTiming=timing)
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
out=dict(sourceFilesVerified=len(json.loads((r/'source-identity.json').read_text())),sameBinary=True,binaryFiles=len(binary),totalRuns=len(results),strictPasses=sum(q['originalReceiptPassed'] for q in results.values()),reassessedPasses=sum(q['reassessmentPassed'] for q in results.values()),results=results,capabilityAccepted=False,physicalOutputVerified=False,audioSynchronizationVerified=False,continuityAccepted=False)
(r/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for n,q in results.items():print(n,'receipt',q['originalReceiptPassed'],'reassessed',q['reassessmentPassed'],'attempts',q['attempts'],'events',[(e['attempt'],e['outcome']) for e in q['events']],'maxGap',q['continuity']['maximumPublishedFrameGapMs'],'errors',q['errors'])
