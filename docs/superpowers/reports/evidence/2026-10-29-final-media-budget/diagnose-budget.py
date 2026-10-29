from pathlib import Path
import json,collections
r=Path('/private/tmp/yl-final-media-budget');p=r/'media/pause-resume'
def read(name):return [json.loads(v) for v in (p/name).read_text().splitlines() if v.strip()]
rows=read('rows.jsonl');frames=read('frame-samples.jsonl');policy=read('policy-decisions.jsonl');receipt=json.loads((p/'receipt.json').read_text());a=json.loads((r/'analysis.json').read_text())['results']['pause-resume'];budget=a['budget'];assert budget
published=[f for f in frames if f['frames']>0];low=budget['secondDownshiftElapsed'];tail=[f for f in published if f['elapsed']>=low]
assert rows[-1]['completed'] and rows[-1]['width']==320
assert all(f['width']==320 for f in tail) and tail[-1]['position']>tail[0]['position']
assert not receipt['passed'] and len(a['errors'])==1 and a['errors'][0]['check']=='production'
assert policy[-1]['attempts']==2 and sum(v['reason']=='reserved' for v in policy)==2
assert all(not v.get('pendingDue') for v in policy if v['elapsed']>=low)
d=dict(strictPassed=False,failedGate='summarize_production_recovery requires final width == 640',actualFinalWidth=rows[-1]['width'],complete=rows[-1]['completed'],position=rows[-1]['position'],budgetExhaustionObservation=budget,policyReasons=dict(collections.Counter(v['reason'] for v in policy)),lowTail=dict(firstElapsed=tail[0]['elapsed'],lastElapsed=tail[-1]['elapsed'],firstPosition=tail[0]['position'],lastPosition=tail[-1]['position'],publishedFrames=sum(v['frames'] for v in tail),generations=sorted(set(v['generation'] for v in tail)),widths=sorted(set(v['width'] for v in tail))),hostFailureCount=rows[-1]['hostFailureCount'],coreMediaErrorCodes=dict(collections.Counter(str(v.get('code')) for v in rows[-1]['errors'])),interpretation='Two eligible windows establish adequate observed bandwidth under the unchanged gate. Attempt two is spent and there is no third reservation. Continued low frames confirm failure of natural high recovery in this run; they do not establish an undocumented AVPlayer penalty timer or justify refunding attempts.',capabilityAccepted=False,continuityAccepted=False,rootCauseEstablished=False)
(r/'budget-failure-diagnosis.json').write_text(json.dumps(d,indent=2)+'\n');print('budget failure diagnosed; raw receipt unchanged')
