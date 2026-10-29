from pathlib import Path
import sys,json,hashlib,collections
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from budget_exhaustion import summarize_budget_exhaustion
from transaction_metrics import summarize_transactions
from proxy_boundaries import record_proxy_observation
r=Path('/private/tmp/yl-budget-metrics');results={};binary=None
for name in ['pause-resume','pause-prepared']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 receipt=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');requests=a.read_rows(p/'requests.jsonl');boundaries=a.read_rows(p/'proxy-requests.jsonl');signals=a.read_rows(p/'signals.jsonl')
 if binary is None:binary=receipt['binaryHashes']
 assert binary==receipt['binaryHashes'] and receipt['binaryIdentityUnchanged'] and receipt['ownedProcessExited']
 checks={};errors=[]
 def check(key,fn):
  try:checks[key]=fn();return checks[key]
  except (ValueError,KeyError,TypeError) as e:errors.append(dict(check=key,error=str(e)))
 check('policy',lambda:a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']))
 check('authority',lambda:a.validate_recovery_authority(rows,checks['policy']))
 check('budget',lambda:summarize_budget_exhaustion(rows,frames,policy))
 if checks.get('budget'):assert receipt['budgetExhaustionObservation']==checks['budget']
 check('production',lambda:a.summarize_production_recovery(rows,frames,require_install=True))
 if name=='pause-resume':check('command',lambda:a.summarize_production_command(rows,checks['policy']))
 else:check('command',lambda:a.summarize_production_race(rows,frames,checks['policy']))
 check('playback',lambda:a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal'))
 proxy={'errors':[]};check('proxy',lambda:record_proxy_observation(proxy,boundaries,requests,3))
 errors.extend(dict(check='proxy',error=e) for e in proxy['errors'])
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished']);assert receipt.get('continuityObservation')==continuity
 phases=[]
 for f in frames:
  if f['frames']>0 and (not phases or phases[-1]['width']!=f['width']):phases.append(dict(width=f['width'],elapsed=f['elapsed']))
 multi=[];states=collections.Counter();incomplete=[]
 for b in boundaries:
  m=b.get('metrics')
  if m:
   for t in m['transactions']:states.update(str(v) for v in t['durationStates'].values())
   if m['transactionCount']>1:multi.append(dict(requestID=b['requestID'],serverRequestID=b.get('serverRequestID'),outcome=b['outcome'],metrics=m))
  if b['outcome']==0 and not summarize_transactions(m)['complete']:incomplete.append(b['requestID'])
 results[name]=dict(receiptPassed=receipt['passed'],nativeExitCode=receipt['exitCode'],errors=errors,receiptErrors=receipt['errors'],budget=checks.get('budget'),production=checks.get('production'),command=checks.get('command'),continuity=continuity,publishedPhases=phases,final={k:rows[-1].get(k) for k in ['elapsed','position','completed','width','automaticAttempts','automaticEvents','hostFailureCount']},signals=signals,proxyCount=len(boundaries),proxyFullyCorrelated=proxy.get('proxyRequestObservation',{}).get('fullyCorrelated'),metricsStateCounts=dict(states),multipleTransactions=multi,incompleteSuccessfulRequests=incomplete,reservations=[d for d in policy if d['reason']=='reserved'],tickets=[d for d in policy if d['reason']=='ticketReady'])
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
if binary:(r/'binary-identity.json').write_text(json.dumps(binary,indent=2)+'\n')
(r/'analysis.json').write_text(json.dumps(dict(results=results,totalRuns=len(results),sameBinary=True,strictPasses=sum(v['receiptPassed'] for v in results.values()),budgetPasses=sum(v['budget'] is not None for v in results.values()),capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False),indent=2)+'\n')
for n,v in results.items():print(n,'budget',v['budget'] is not None,'strict',v['receiptPassed'],'errors',v['errors'],'phases',v['publishedPhases'])
