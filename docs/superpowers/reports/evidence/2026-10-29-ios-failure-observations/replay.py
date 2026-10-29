from pathlib import Path
import json,hashlib,sys,subprocess
sys.path.insert(0,'tool/playback_network')
import abr_accesslog as a
from proxy_boundaries import record_proxy_observation,summarize_proxy_boundaries
r=Path('/private/tmp/yl-failure-observations');old=Path('/private/tmp/yl-same-resource-retry');results={}
for n in ['normal','normal-repeat','normal-third','original']:
 p=old/'media'/n;before={v.name:hashlib.sha256(v.read_bytes()).hexdigest() for v in p.glob('*.json*')}
 original=json.loads((p/'receipt.json').read_text());rows=a.read_rows(p/'rows.jsonl');frames=a.read_rows(p/'frame-samples.jsonl');policy=a.read_rows(p/'policy-decisions.jsonl');boundaries=a.read_rows(p/'proxy-requests.jsonl');servers=a.read_rows(p/'requests.jsonl')
 d={'errors':[],'reanalysisOnly':True,'originalReceiptPassed':original['passed'],'capabilityAccepted':False,'physicalOutputVerified':False}
 record_proxy_observation(d,boundaries,servers,6)
 d['policyObservation']=a.summarize_policy(policy,expected_attempts=rows[-1]['automaticAttempts']);a.validate_recovery_authority(rows,d['policyObservation'])
 d['continuityObservation']=a.summarize_frames(frames,expected_frames=rows[-1]['framesPublished'])
 d['productionRecoveryObservation']=a.summarize_production_recovery(rows,frames,require_install=n!='original')
 d['observation']=a.summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload',expected_auto_scenario='normal')
 d['strictReanalysisPassed']=not d['errors'];assert d['strictReanalysisPassed']==original['passed']
 cmd=['python3','-B','tool/playback_network/bandwidth_diagnostics.py',str(p),'--profiles',str(old/'profiles.json')]
 q=subprocess.run(cmd,capture_output=True,text=True);(r/(n+'-replay-cli.stdout')).write_text(q.stdout);(r/(n+'-replay-cli.stderr')).write_text(q.stderr)
 diag=json.loads(q.stdout);assert bool(q.returncode)==bool(d['errors']) and diag['errors']==d['errors']
 d['cli']=dict(command=cmd,exitCode=q.returncode)
 assert before=={v.name:hashlib.sha256(v.read_bytes()).hexdigest() for v in p.glob('*.json*')};d['originalRawHashesUnchanged']=before
 (r/(n+'-reanalysis.json')).write_text(json.dumps(d,indent=2)+'\n')
 results[n]=dict(oldPassed=original['passed'],newPassed=d['strictReanalysisPassed'],errors=d['errors'],proxyCount=d['proxyRequestObservation']['requestCount'],uncorrelated=d['proxyRequestObservation']['uncorrelatedProxyRequests'],incompleteSuccesses=d.get('proxyRequestValidationErrors',[]),framesRetained=True,cliExit=q.returncode,rawHashesUnchanged=True)
(r/'replay-results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
