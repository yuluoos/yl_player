import json,re,sys,hashlib
from pathlib import Path
run=Path(sys.argv[1])
def rows(name):return [json.loads(l) for l in (run/name).read_text().splitlines()]
raw=rows('proxy-requests.jsonl');sidecar=rows('transaction-connections.jsonl');logs=rows('client-network.jsonl')
receipt=json.loads((run/'receipt.json').read_text())
ident=lambda r:(r['proxyID'].lower(),r['requestID'])
boundaries={ident(r):r for r in raw};links={ident(r):r for r in receipt['transactionConnectionObservation']['requests']}
proof=json.loads((run/'process.json').read_text())
assert all(r['pid']==proof['pid'] for r in logs)
index={};connections={}
for i,r in enumerate(logs):
 message=r['message']
 for task in set(re.findall(r'Task (<[0-9a-fA-F-]{36}>\.<[0-9]+>)',message)):
  index.setdefault(task.lower(),[]).append(i)
 for c in set(re.findall(r'\[C(\d+)(?=[:. \]])',message)+re.findall(r'^Connection (\d+):',message)):
  connections.setdefault(int(c),[]).append(i)
results=[]
for row in sidecar:
 task=row['foundationTaskID'];indices=index.get(task,[]);connection_ids=set()
 for i in indices:
  message=logs[i]['message']
  connection_ids.update(map(int,re.findall(r'\bConnection (\d+)\b',message)+re.findall(r'\bconnection=(\d+)\b',message)))
 b=boundaries[ident(row)];link=links[ident(row)]
 target=(len(row['transactions'])>1 or any(t['binding']!='bound' or not t['responsePresent'] for t in link['transactions']))
 results.append(dict(proxyID=row['proxyID'],requestID=row['requestID'],foundationTaskID=task,
  targetPhenomenon=target,outcome=b['outcome'],cancelCause=b['cancelCause'],
  taskLogIndices=indices,connectionIDs=sorted(connection_ids),
  connectionLogIndices=sorted({i for c in connection_ids for i in connections.get(c,[])})))
summary=dict(passed=receipt['passed'],errors=receipt['errors'],taskCount=len(raw),
 taskIdentityCount=sum(r['foundationTaskID'] is not None for r in results),
 taskLogMatchedCount=sum(bool(r['taskLogIndices']) for r in results),clientLogCount=len(logs),
 targetCount=sum(r['targetPhenomenon'] for r in results),
 packetCapture=receipt.get('packetCaptureObservation'),
 rootCauseEstablished=False,requests=results,
 sourceLogSHA256=hashlib.sha256((run/'client-network.jsonl').read_bytes()).hexdigest())
(run/'task-log-attribution.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if k!='requests'},indent=2))
for r in results:
 if r['targetPhenomenon']:
  print(json.dumps(r))
  for i in r['taskLogIndices']:print(logs[i]['message'][:2400])
