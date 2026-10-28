from pathlib import Path
import json,hashlib,gzip,sys
sys.path.insert(0,'tool/playback_network')
from abr_accesslog import summarize,summarize_policy,summarize_frames,validate_recovery_authority
r=Path('/private/tmp/yl-abr-original-recovery')
def read(p):
 b=gzip.decompress(p.read_bytes()) if p.suffix=='.gz' else p.read_bytes()
 return [json.loads(x) for x in b.decode().splitlines()]
def analyze(p,compressed=False):
 suffix='.gz' if compressed else ''
 rows=read(p/('rows.jsonl'+suffix));pol=read(p/('policy-decisions.jsonl'+suffix));frames=read(p/('frame-samples.jsonl'+suffix));signals=(read(p/('signals.jsonl'+suffix)) if not compressed else None)
 po=summarize_policy(pol,expected_attempts=rows[-1]['automaticAttempts']);validate_recovery_authority(rows,po)
 ob=summarize(rows,expected_duration_seconds=120,expected_transport='managed-dash',expected_recovery_action='auto-reload')
 co=summarize_frames(frames,expected_frames=rows[-1]['framesPublished'])
 transitions=[]
 for x in rows:
  if not transitions or transitions[-1]['width']!=x['width']:transitions.append({k:x[k] for k in ['elapsed','position','width']})
 decisive=[{k:x.get(k) for k in ['elapsed','reason','windowBitrate','windowRequests','qualifiedWindows','pendingDue','attempts']} for x in pol if x['reason'] in ['firstQualifiedWindow','reserved','ticketReady','insufficientBandwidth','insufficientRequests','noProgress','countersReset']]
 return dict(completed=rows[-1]['completed'],position=rows[-1]['position'],elapsed=rows[-1]['elapsed'],transitions=transitions,decisivePolicy=decisive,reasonCounts=po['reasonCounts'],attempts=po['attempts'],tickets=po['tickets'],events=rows[-1]['automaticEvents'],signals=signals,observation=ob,continuity=co,actualHighPublishedFrames=sum(x['frames'] for x in frames if x.get('width')==640),highFramesAfterInstall=[dict(attempt=e['attempt'],frames=sum(x['frames'] for x in frames if x['elapsed']>e['elapsedAfter'] and x.get('width')==640)) for e in rows[-1]['automaticEvents'] if e['outcome']=='installed'],diagnosticOnly=True,capabilityAccepted=False)
result={'current':{},'historical':{}}
for name in ['original','zero-latency']:
 p=r/'network-restored-media'/name
 result['current'][name]=analyze(p)
 receipt=json.loads((p/'receipt.json').read_text()); result['current'][name]['receiptPassed']=receipt['passed']
for name in ['original-control','auto-control']:
 result['historical'][name]=analyze(Path('docs/superpowers/reports/evidence/2026-10-28-ios-policy-intent/media')/name,True)
identity=json.loads((r/'source-identity.json').read_text())
for p,h in identity.items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
result['sourceFilesUnchanged']=len(identity)
(r/'analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for name,x in result['current'].items():print(name,{k:x[k] for k in ['receiptPassed','completed','position','transitions','decisivePolicy','attempts','tickets','signals']},'boundaries',x['continuity']['replacementBoundaries'])
