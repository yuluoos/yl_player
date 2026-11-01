"""Summarize the completed same-binary VPN experiment without causal inference."""
import json
from pathlib import Path
import sys
root=Path(sys.argv[1]);names=['task-linked','nextin-off','nextin-on','nextin-on-authorized']
baseline=json.loads((root/names[0]/'receipt.json').read_text())['binaryHashes']
results=[]
for name in names:
 run=root/name;receipt=json.loads((run/'receipt.json').read_text())
 item=dict(run=name,passed=receipt['passed'],exitCode=receipt['exitCode'],errors=receipt['errors'],
     sameBinaryHashesAsFirstRun=receipt['binaryHashes']==baseline,
     packetCapture=receipt['packetCaptureObservation'])
 if (run/'task-log-attribution.json').exists():
  tasks=json.loads((run/'task-log-attribution.json').read_text())
  item.update({k:tasks[k] for k in ['taskCount','taskIdentityCount','taskLogMatchedCount','clientLogCount','targetCount']})
 if (run/'packet-summary.json').exists():
  packets=json.loads((run/'packet-summary.json').read_text());item['flowCount']=len(packets['flows'])
  times=sorted(p['relativeTimeSeconds'] for f in packets['flows'] for p in f['packets'] if p['direction']=='client')
  a,b=max(zip(times,times[1:]),key=lambda pair:pair[1]-pair[0])
  item['largestClientPacketGapSeconds']=b-a;item['clientPacketGapRelativeSeconds']=[a,b]
 if (run/'rows.jsonl').exists():
  rows=[json.loads(l) for l in (run/'rows.jsonl').read_text().splitlines()]
  if rows:item['lastPlaybackSample']={k:rows[-1][k] for k in ['elapsed','position','hostStatus','completed','automaticAttempts']}
 results.append(item)
output=dict(conditions=json.loads((root/'experiment-conditions.json').read_text()),runs=results,
    nextinCauseEstablished=False,physicalBufferingComponentEstablished=False,
    historicalCasesClosed=False,interpretation='One failed run and individual controls do not prove an intermittent VPN cause. Capture startup failures are not playback runs. Same binary hashes do not establish identical radio conditions.')
(root/'experiment-summary.json').write_text(json.dumps(output,indent=2)+'\n')
for item in results: print(json.dumps(item))
