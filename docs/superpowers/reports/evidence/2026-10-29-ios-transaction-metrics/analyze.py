from pathlib import Path
import json,sys,hashlib,statistics
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from proxy_boundaries import record_proxy_observation
from network_profile import load_profiles
r=Path('/private/tmp/yl-transaction-metrics');profiles={**load_profiles(r/'profiles.json'),**load_profiles(r/'recovery-profiles.json')};results={};binaries={}
for name in ['final-original','final-recovery-control']:
 p=r/'media'/name
 if not (p/'receipt.json').exists():continue
 d=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');signals=a.read_rows(p/'signals.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');requests=a.read_rows(p/'requests.jsonl');boundaries=a.read_rows(p/'proxy-requests.jsonl')
 stage='final' if name.startswith('final-') else 'pre-review'
 if stage not in binaries:binaries[stage]=d['binaryHashes']
 assert binaries[stage]==d['binaryHashes'] and d['binaryIdentityUnchanged'] and d['ownedProcessExited']
 reassessment={'errors':[]};record_proxy_observation(reassessment,boundaries,requests,2);proxy=reassessment['proxyRequestObservation']
 production=None
 try:production=a.summarize_production_recovery(rows,frames);a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal')
 except ValueError as e:reassessment['errors'].append(str(e))
 continuity=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished']);assert continuity==d['continuityObservation']
 summary=a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']);assert summary==d['policyObservation']
 published=[f for f in frames if f['frames']>0];phases=[];sawHigh=False;sawLow=False;recoverIndex=None
 for i,f in enumerate(published):
  if not phases or phases[-1]['width']!=f['width']:phases.append(dict(width=f['width'],elapsed=f['elapsed']))
  if f['width']==640:
   if sawLow and recoverIndex is None:recoverIndex=i
   sawHigh=True
  elif f['width']==320 and sawHigh:sawLow=True
 high=published[recoverIndex:] if recoverIndex is not None else []
 server={x['requestId']:x for x in requests};profile=profiles[requests[0]['profile']];phaseStats=[]
 for i,step in enumerate(profile.steps):
  stop=profile.steps[i+1]['atMs'] if i+1<len(profile.steps) else float('inf')
  entries=[x for x in proxy['requests'] if x['outcome']=='complete' and x['serverRequestID'] is not None and step['atMs']<=server[x['serverRequestID']]['startMs'] and server[x['serverRequestID']]['endMs']<=stop]
  fields=['bodyBytes','serverSeconds','upstreamSeconds','responseWaitSeconds','bodyCallbackSpanSeconds','sendWaitSumSeconds','upstreamMinusServerSeconds']
  transaction_sums={key:sum(t[key] for x in entries for t in x['transactionMetrics']['transactions'] if t[key] is not None) for key in ['fetchSeconds','fetchToRequestSeconds','dnsSeconds','connectSeconds','tlsSeconds','requestSeconds','responseWaitSeconds','responseSeconds']}
  transaction_presence={key:sum(t[key] is not None for x in entries for t in x['transactionMetrics']['transactions']) for key in transaction_sums}
  phaseStats.append(dict(transactionSums=transaction_sums,transactionObservedCounts=transaction_presence,transactionCount=sum(len(x['transactionMetrics']['transactions']) for x in entries),reusedCount=sum(t['reused'] for x in entries for t in x['transactionMetrics']['transactions']),taskSecondsSum=sum(x['transactionMetrics']['taskSeconds'] for x in entries),phaseIndex=i,requests=len(entries),sums={k:sum(x[k] or 0 for x in entries) for k in fields},sendWaitMaximumSeconds=max((x['sendWaitMaxSeconds'] for x in entries),default=None),upstreamMedianSeconds=statistics.median(x['upstreamSeconds'] for x in entries) if entries else None))
 results[name]=dict(stage=stage,originalReceiptPassed=d['passed'],nativeExitCode=d['exitCode'],finalReassessmentPassed=not reassessment['errors'] and d['exitCode']==0 and not signals,reassessmentErrors=reassessment['errors'],position=rows[-1]['position'],finalWidth=rows[-1]['width'],completed=rows[-1]['completed'],signals=signals,hostFailureCount=rows[-1]['hostFailureCount'],attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],publishedPhases=phases,production=production,continuity=continuity,stableHighAfterRecovery=bool(high) and all(f['width']==640 for f in high),highTailSeconds=high[-1]['elapsed']-high[0]['elapsed'] if high else None,policyRange=[summary['windowBitrateMinimum'],summary['windowBitrateMaximum']],policyReasons=summary['reasonCounts'],proxySummary={k:v for k,v in proxy.items() if k!='requests'},phaseRequestBoundaries=phaseStats,lastAccessLogs=rows[-1]['logs'])
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
out=dict(sameBinaryWithinEachStage=True,binaryHashesByStage=binaries,sourceFilesVerified=414,totalRuns=len(results),finalRuns=sum(x['stage']=='final' for x in results.values()),finalPassed=sum(x['stage']=='final' and x['finalReassessmentPassed'] for x in results.values()),results=results,capabilityAccepted=False,physicalOutputVerified=False,continuityAccepted=False)
(r/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
for name,x in results.items():print(name,x['originalReceiptPassed'],x['finalReassessmentPassed'],'attempts',x['attempts'],'highTail',x['highTailSeconds'],'maxGap',x['continuity']['maximumPublishedFrameGapMs'],'correlated',x['proxySummary']['fullyCorrelated'])
