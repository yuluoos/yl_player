from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-production-recovery');results={};binary=None
for n in ['original','zero-latency','pause-resume']:
 p=r/'reviewed-media'/n;d=json.loads((p/'receipt.json').read_text());rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()]
 assert d['passed'] and not d['errors'] and d['binaryIdentityUnchanged'] and d['ownedProcessExited']
 if binary is None:binary=d['binaryHashes']
 else:assert binary==d['binaryHashes']
 assert not (p/'signals.jsonl').read_text().strip()
 assert rows[-1]['completed'] and rows[-1]['width']==640
 results[n]=dict(passed=d['passed'],finalPosition=rows[-1]['position'],attempts=rows[-1]['automaticAttempts'],events=rows[-1]['automaticEvents'],policy={k:v for k,v in d['policyObservation'].items() if k!='credentialRevisions' and (not isinstance(v,list) or len(v)<5)},production=d['productionRecoveryObservation'],command=d.get('productionCommandObservation'),continuity=d['continuityObservation'],profileSha256=d['profileSha256'],signals=0)
(r/'final-media-analysis.json').write_text(json.dumps(dict(sameBinary=True,binaryHashes=binary,results=results),indent=2)+'\n')
print('final three media receipts, EOF, unchanged binary and signals verified')
