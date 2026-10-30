from pathlib import Path
import json,sys,hashlib
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from budget_exhaustion import summarize_budget_exhaustion
from proxy_boundaries import record_proxy_observation
from connection_lifecycle import summarize_lifecycle
from transaction_metrics import summarize_transactions
r=Path('/private/tmp/yl-failure-observations');results={};binary=json.loads((r/'binary-identity.json').read_text())
for name in ['normal','original']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');requests=a.read_rows(p/'requests.jsonl');boundaries=a.read_rows(p/'proxy-requests.jsonl');signals=a.read_rows(p/'signals.jsonl');checks={};errors=[]
 assert d['binaryHashes']==binary and d['binaryIdentityUnchanged'] and d['ownedProcessExited']
 def check(key,fn):
  try:checks[key]=fn();return checks[key]
  except (ValueError,KeyError,TypeError) as e:errors.append(dict(check=key,error=str(e)))
 check('policy',lambda:a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']))
 check('authority',lambda:a.validate_recovery_authority(rows,checks['policy']))
 check('production',lambda:a.summarize_production_recovery(rows,frames,require_install=not name.startswith('original')))
 check('playback',lambda:a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal'))
 if name=='pause-resume':
  check('budget',lambda:summarize_budget_exhaustion(rows,frames,policy));check('command',lambda:a.summarize_production_command(rows,checks['policy']))
  if checks.get('budget'):assert checks['budget']==d['budgetExhaustionObservation']
 proxy={'errors':[]};check('proxy',lambda:record_proxy_observation(proxy,boundaries,requests,6));errors.extend(dict(check='proxy',error=e) for e in proxy['errors'])
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished']);assert 'continuityObservation' not in d or continuity==d['continuityObservation']
 lifecycle=summarize_lifecycle(json.loads((p/'connection-lifecycle.json').read_text()),requests);assert lifecycle==d['connectionLifecycleObservation']
 if not lifecycle['complete']:errors.append(dict(check='lifecycle',error='incomplete'))
 if signals:errors.append(dict(check='signals',error='interruption'))
 if d['exitCode']!=0:errors.append(dict(check='native',error=str(d['exitCode'])))
 published=[f for f in frames if f['frames']>0];phases=[]
 for f in published:
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(elapsed=f['elapsed'],width=f['width'],generation=f['generation']))
 events=rows[-1]['automaticEvents'];installs=[e for e in events if e['outcome']=='installed'];proof=None
 if not name.startswith('original') and len(installs)==2:
  first,second=installs;high1=next((f for f in published if first['elapsedAfter']<f['elapsed']<second['elapsed'] and f['width']==640),None)
  low2=next((f for f in published if high1 and high1['elapsed']<f['elapsed']<second['elapsed'] and f['width']==320),None)
  high2=next((f for f in published if f['elapsed']>second['elapsedAfter'] and f['width']==640),None)
  assert [e['attempt'] for e in installs]==[1,2] and high1 and low2 and high2
  assert high1['generation']==low2['generation'] and high2['generation']!=low2['generation']
  tail=[f for f in published if f['elapsed']>=high2['elapsed']]
  proof=dict(firstHigh=high1['elapsed'],secondLow=low2['elapsed'],secondInstall=second['elapsedAfter'],secondHigh=high2['elapsed'],highTailSeconds=tail[-1]['elapsed']-tail[0]['elapsed'],stableHighTail=all(f['width']==640 for f in tail),capabilityAccepted=False)
 if not name.startswith('original') and proof is None:errors.append(dict(check='secondInstall',error='two installs with fresh high-low-high sequence not established'))
 multi=[b for b in boundaries if (b.get('metrics') or {}).get('transactionCount',0)>1]
 settlement=dict(incompleteMetrics=sum(not summarize_transactions(b.get('metrics'))['complete'] for b in boundaries),total=len(boundaries),taskCompleted=sum('taskComplete' in b for b in boundaries),
  cancelled=sum(b['outcome']==1 for b in boundaries),cancelledWithMetrics=sum(b['outcome']==1 and b.get('metrics') is not None for b in boundaries),
  cancelledWithTaskCancelled=sum(b['outcome']==1 and b.get('taskOutcome')==1 for b in boundaries),
  taskOutcomeCounts={str(code):sum(b.get('taskOutcome')==code for b in boundaries) for code in (0,1,2)},
  metricsMissing=[b['requestID'] for b in boundaries if b.get('metrics') is None],
  settledAfterDownstream=sum(b['taskComplete']>b['downstreamTerminal'] for b in boundaries),
  maximumPostCloseSettlementMs=max((b['taskComplete']-b['downstreamTerminal'])*1000 for b in boundaries),
  capabilityAccepted=False)
 results[name]=dict(settlement=settlement,receiptPassed=d['passed'],nativeExitCode=d['exitCode'],reassessmentPassed=not errors,errors=errors,receiptErrors=d['errors'],budget=checks.get('budget'),secondInstallProof=proof,production=checks.get('production'),command=checks.get('command'),policy=checks.get('policy'),continuity=continuity,lifecycle=lifecycle,publishedPhases=phases,final={k:rows[-1].get(k) for k in ['elapsed','position','completed','width','automaticAttempts','automaticEvents','hostFailureCount','logs','errors']},signals=signals,proxyCount=len(boundaries),proxyFullyCorrelated=proxy.get('proxyRequestObservation',{}).get('fullyCorrelated'),multipleTransactions=multi,incompleteSuccessfulRequests=[b['requestID'] for b in boundaries if b['outcome']==0 and not summarize_transactions(b.get('metrics'))['complete']],reservations=[v for v in policy if v['reason']=='reserved'],tickets=[v for v in policy if v['reason']=='ticketReady'])
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
(r/'analysis.json').write_text(json.dumps(dict(results=results,totalRuns=len(results),strictPasses=sum(v['receiptPassed'] for v in results.values()),reassessedPasses=sum(v['reassessmentPassed'] for v in results.values()),sameBinary=True,capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False),indent=2)+'\n')
for n,q in results.items():print(n,'strict',q['receiptPassed'],'errors',q['errors'],'secondInstall',q['secondInstallProof'],'lifecycle',q['lifecycle'])
