from pathlib import Path
import json,gzip,hashlib,sys
sys.path.insert(0,'tool/playback_network');from proxy_boundaries import record_proxy_observation
r=Path('/private/tmp/yl-reset-retry-control');e=Path('docs/superpowers/reports/evidence');prior=json.loads((e/'2026-10-29-loopback-error-source/byte-replay/results.json').read_text());result={}
for label,d in prior.items():
 base,name=label.split('/');group={'yl-same-resource-retry':'2026-10-29-ios-same-resource-retry','yl-transaction-bytes':'2026-10-29-ios-transaction-bytes'}[base]
 root=e/group/'media'/name
 def read(n):
  p=root/n;data=p.read_bytes() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes())
  assert hashlib.sha256(data).hexdigest()==d['originalRawHashes'][n],(label,n)
  return data
 for n in d['originalRawHashes']:read(n)
 proxy=[json.loads(x) for x in read('proxy-requests.jsonl').splitlines() if x.strip()];server=[json.loads(x) for x in read('requests.jsonl').splitlines() if x.strip()]
 receipt={'errors':[]};record_proxy_observation(receipt,proxy,server,6);assert receipt['errors']==d['proxyErrors']
 result[label]=dict(oldPassed=d['oldPassed'],proxyErrors=receipt['errors'],originalRawHashes=d['originalRawHashes'],archiveRoot=str(root),capabilityAccepted=False)
(r/'byte-replay').mkdir(exist_ok=True);(r/'byte-replay/results.json').write_text(json.dumps(result,indent=2)+'\n');print('archived replay',len(result),'old pass',sum(v['oldPassed'] for v in result.values()))
