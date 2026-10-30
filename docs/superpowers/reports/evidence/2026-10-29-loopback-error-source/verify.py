from pathlib import Path
import json,hashlib,subprocess,gzip,tarfile,sys
r=Path('/private/tmp/yl-loopback-error-source');out=Path('docs/superpowers/reports/evidence/2026-10-29-loopback-error-source');sha=lambda x:hashlib.sha256(x).hexdigest()
for n,h in json.loads((r/'media-raw-identity.json').read_text()).items():assert sha((r/'media'/n).read_bytes())==h
source=json.loads((r/'source-identity.json').read_text())
for p,h in source.items():assert sha(Path(p).read_bytes())==h,p
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((r/'binary-identity.json').read_text())
base=json.loads(subprocess.check_output(['git','show','6b468200:tool/release_readiness/inventory.json']));cur=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(cur['rows'])==102
changed=[p for p,h in base['source']['files'].items() if cur['source']['files'].get(p)!=h];assert changed==['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift'],changed
for a,b in zip(base['rows'],cur['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
 assert len(b['evidence'])==len(set(b['evidence']))<=20
assert all(cur['evidence'][k]==v for k,v in base['evidence'].items())
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2 and a['sameBinary'] and not a['capabilityAccepted'] and not a['continuityAccepted'] and not a['physicalOutputVerified']
executions=json.loads((r/'media/results.json').read_text());assert len(executions)==2
for n,d in a['results'].items():
 summary=json.loads((r/'media'/(n+'-summary.json')).read_text());assert summary['totalTestCount']==summary['passedTests']==1 and summary['failedTests']==summary['skippedTests']==0
 execution=next(x for x in executions if x['name']==n);assert execution['exitCode']==(0 if d['receiptPassed'] else 1)
 receipt=json.loads((r/'media'/n/'receipt.json').read_text());assert receipt['passed']==d['receiptPassed'] and receipt['binaryHashes']==binary and receipt['ownedProcessExited'] and receipt['binaryIdentityUnchanged']
 assert not d['continuity']['continuityAccepted'] and not d['continuity']['physicalOutputVerified'] and not d['continuity']['audioSynchronizationVerified']
 assert receipt['passed']==d['reassessmentPassed']
 if n.startswith('budget-'):assert receipt['budgetExhaustionObservation']==d['budget'] and d['budget']['maximumAttempts']==2 and not d['budget']['thirdReservationObserved']
 assert not d['signals']
for platform,c in [('ios',256),('macos',231)]:
 d=json.loads((r/(platform+'-final-summary.json')).read_text());assert d['passedTests']==d['totalTestCount']==c and d['failedTests']==d['skippedTests']==0
 assert json.loads((r/(platform+'-final-result.json')).read_text())['exitCode']==0
replay=json.loads((r/'byte-replay/results.json').read_text());assert len(replay)==6 and sum(v['oldPassed'] for v in replay.values())==3
for name,d in replay.items():
 root=Path('/private/tmp')/name.split('/')[0]/'media'/name.split('/')[1]
 for n,h in d['originalRawHashes'].items():assert sha((root/n).read_bytes())==h
history=json.loads((r/'history.json').read_text());assert len(history)==48
for row in history:
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256']
 assert p.read_bytes()==subprocess.check_output(['git','show','6b468200:'+str(p)])
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
assert 'Ran 203 tests' in (r/'tools.log').read_text() and '\nOK\n' in (r/'tools.log').read_text()
assert 'Ran 46 tests' in (r/'consumer.log').read_text() and 'OK (skipped=1)' in (r/'consumer.log').read_text()
assert all(x['exitCode']==0 for x in json.loads((r/'offline-results.json').read_text()))
assert all(v['exitCode']==v['expected'] for v in json.loads((r/'readiness-results.json').read_text()))
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
e=cur['evidence']['loopback-error-source-20261029'];assert sha(Path(e['path']).read_bytes())==e['sha256']
bundles=0;records=json.loads((out/'raw-provenance.json').read_text());assert any(x['source']=='review-final.md' for x in records)
for row in records:
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
assert bundles==5,bundles
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
print(json.dumps(dict(completeXcresults=bundles,newNative=dict(ios=256,macos=231),sourceFiles=len(source),binaryFiles=len(binary),newLongMediaRuns=2,strictPasses=a['strictPasses'],reassessedPasses=a['reassessedPasses'],historicalGroups=48,historicalHashEntries=sum(x['files'] for x in history),ledgerStatusesUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
