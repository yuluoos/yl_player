from pathlib import Path
import json,hashlib,subprocess,gzip,tarfile
r=Path('/private/tmp/yl-half-close-fix');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-half-close-fix');sha=lambda b:hashlib.sha256(b).hexdigest()
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert sha(Path(p).read_bytes())==h
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert len(binary)==307 and binary==json.loads((r/'binary-identity.json').read_text())
base=json.loads(subprocess.check_output(['git','show','28ddf707:tool/release_readiness/inventory.json']));cur=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(cur['rows'])==102
for a,b in zip(base['rows'],cur['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(cur['evidence'][k]==v for k,v in base['evidence'].items())
changed=[p for p in set(base['source']['files'])|set(cur['source']['files']) if base['source']['files'].get(p)!=cur['source']['files'].get(p)];assert len(changed)==1 and changed[0].endswith('/YlHlsMediaProxy.swift')
for n,c in [('ios-fixed',253),('macos-fixed',228)]:
 d=json.loads((r/(n+'-summary.json')).read_text());assert d['passedTests']==d['totalTestCount']==c and d['failedTests']==d['skippedTests']==0
 bound=json.loads((r/(n.split('-')[0]+'-binding/case-identities.json')).read_text())['summary'];assert all(bound[k]==d[k] for k in ('totalTestCount','passedTests','failedTests','skippedTests'))
for n in ('native-probe-red','ios-final','macos-final'):assert json.loads((r/(n+'-result.json')).read_text())['exitCode']==65
assert json.loads((r/'native-probe-green-result.json').read_text())['exitCode']==0
probes=json.loads((r/'probe-validation.json').read_text());assert len(probes)==4
for platform in ('ios','macos'):
 assert all(v['receivedExpectedBody'] for v in probes[platform+'/response']['observations'])
 for v in probes[platform+'/deadline']['samples']:
  assert v['elapsed']<2.5 and all(v['snapshot'][k]==0 for k in ('activeTasks','activeConnections','activeRequestTraces','connectionDeadlines'))
  if v['mode']==3:
   t=v['traces'][0];assert t['outcome']==1 and t['cancelCause']==4 and t['sendCount']>t['sendCompletions'] and t['bodyBytes']>t['sentBodyBytes']
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2 and a['sameBinary'] and not a['capabilityAccepted'] and not a['continuityAccepted']
for n,d in a['results'].items():
 receipt=json.loads((r/'media'/n/'receipt.json').read_text());assert receipt['passed']==d['receiptPassed']==d['reassessmentPassed'] and receipt['binaryHashes']==binary and receipt['ownedProcessExited'] and receipt['binaryIdentityUnchanged']
 assert not d['continuity']['continuityAccepted']
replay=json.loads((r/'byte-replay/results.json').read_text());assert len(replay)==6 and sum(v['oldPassed'] for v in replay.values())==3
for name,d in replay.items():
 root=Path('/private/tmp')/name.split('/')[0]/'media'/name.split('/')[1]
 for n,h in d['originalRawHashes'].items():assert sha((root/n).read_bytes())==h
history=json.loads((r/'history.json').read_text());assert len(history)==44
for row in history:
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256']
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
assert 'Ran 200 tests' in (r/'tools.log').read_text() and '\nOK\n' in (r/'tools.log').read_text()
assert 'Ran 46 tests' in (r/'consumer-final.log').read_text() and 'OK (skipped=1)' in (r/'consumer-final.log').read_text()
bundles=0
for row in json.loads((out/'raw-provenance.json').read_text()):
 if 'archiveParts' in row:
  bundles+=1;temp=r/'verify.tar.gz';digest=hashlib.sha256()
  with temp.open('wb') as f:
   for part in row['archiveParts']:
    data=(out/part['path']).read_bytes();assert sha(data)==part['sha256'];digest.update(data);f.write(data)
  assert digest.hexdigest()==row['archiveSha256']
  with tarfile.open(temp,'r:gz') as t:actual={str(Path(m.name).relative_to(row['source'])):sha(t.extractfile(m).read()) for m in t.getmembers() if m.isfile()}
  assert actual==row['bundleFiles'];temp.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256'];assert sha(gzip.decompress(data) if row['compressed'] else data)==row['sourceSha256']==sha((r/row['source']).read_bytes())
assert bundles==8
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
assert all(v['exitCode']==v['expected'] for v in json.loads((r/'readiness-results.json').read_text()))
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
print(json.dumps(dict(completeXcresults=bundles,selectedNative={'ios':253,'macos':228},sourceFiles=438,binaryFiles=307,mediaStrictPasses=a['strictPasses'],mediaReassessedPasses=a['reassessedPasses'],historicalGroups=44,historicalHashEntries=sum(v['files'] for v in history),ledgerStatusesUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
