from pathlib import Path
import json,hashlib,sys,traceback
raw=Path('/private/tmp/yl-public-transport');sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');import main_example_tests as gate
classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'};scope={}
for mode,platform,count in [('device','ios',205),('macos','macos',180)]:
 tree=json.loads((raw/('review-'+mode+'-contracts-tests.json')).read_text());nodes=list(gate.case_nodes(tree['testNodes']));ids=[n['nodeIdentifier'] for n in nodes]
 expected={i for i in gate.expected_identities(Path('tool/consumer_fixtures/apple_flutter'),platform) if i.split('/')[0] in classes}
 assert len(ids)==len(set(ids))==count and set(ids)==expected and all(n['result']=='Passed' for n in nodes)
 scope[mode]=dict(passed=count,failed=0,skipped=0,classes={c:sum(i.startswith(c+'/') for i in ids) for c in sorted(classes) if any(i.startswith(c+'/') for i in ids)})
(raw/'final-native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'review-source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
sys.path.insert(0,'tool/playback_network');import abr_accesslog
results=[]
for phase in ['media','review-media']:
 for name in ['pause','seek']:
  p=raw/phase/name
  if not (p/'receipt.json').exists():continue
  r=json.loads((p/'receipt.json').read_text()); rows,frames,decisions,signals=[list(map(json.loads,(p/f).read_text().splitlines())) for f in ['rows.jsonl','frame-samples.jsonl','policy-decisions.jsonl','signals.jsonl']]
  e=rows[-1]['automaticEvents'][0];start=e['publicCommandCompletedElapsed'] if name=='seek' else rows[-1]['publicResume']['completedElapsed']
  published=[f for f in frames if f['elapsed']>=start and f['frames']>0]
  target=e.get('publicSeekTargetMs',0)/1000
  pts=[t for f in published for t in f.get('framePresentationTimes',[])];bad=[f for f in published if len(f.get('framePresentationTimes',[]))!=f['frames'] or any(type(t) not in (float,int) or t<target-.05 for t in f.get('framePresentationTimes',[]))]
  try:abr_accesslog.summarize_public_transport(rows,frames,abr_accesslog.summarize_policy(decisions,expected_attempts=rows[-1]['automaticAttempts']));failure=None
  except Exception:
   failure=traceback.format_exc()
  m=dict(phase=phase,name=name,passed=r['passed'],completed=rows[-1]['completed'],position=rows[-1]['position'],signals=signals,event=e,automaticEvents=rows[-1]['automaticEvents'],resume=rows[-1].get('publicResume'),attempts=rows[-1]['automaticAttempts'],postCommandFrames=sum(f['frames'] for f in published),postCommandWidths=sorted(set(f['width'] for f in published)),ptsCount=len(pts),invalidPTSRows=len(bad),ptsMinimum=min(pts) if pts and all(type(t) in (int,float) for t in pts) else None,seekTarget=target if name=='seek' else None,policy=r.get('policyObservation'),continuity=r.get('continuityObservation'),validatorFailure=failure,binaryIdentityUnchanged=r['binaryIdentityUnchanged'],ownedProcessExited=r['ownedProcessExited'])
  results.append(m)
(raw/'final-media-analysis.json').write_text(json.dumps(results,indent=2)+'\n')
final=[m for m in results if m['phase']=='review-media']
if len(final)==2:
 rs=[json.loads((raw/'review-media'/n/'receipt.json').read_text()) for n in ['pause','seek']]
 assert all(r['binaryIdentityUnchanged'] and r['ownedProcessExited'] and r['binaryHashes']==rs[0]['binaryHashes'] for r in rs)
 products=Path('/private/tmp/yl-public-policy-ios/Build/Products')
 for p,h in rs[0]['binaryHashes'].items():assert sha((products/p).read_bytes())==h,p
 (raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,sameBinary=True,productsStillMatch=True,ownedProcessesExited=True,mediaRuns=['review-media/pause','review-media/seek']),indent=2)+'\n')
for m in results:print({k:m[k] for k in ['phase','name','passed','completed','position','attempts','postCommandWidths','ptsCount','invalidPTSRows','ptsMinimum','seekTarget','signals']})
