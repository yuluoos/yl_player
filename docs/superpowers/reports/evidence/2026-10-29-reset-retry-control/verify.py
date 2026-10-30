from pathlib import Path
import json,hashlib,subprocess,gzip,tarfile,sys
r=Path('/private/tmp/yl-reset-retry-control');out=Path('docs/superpowers/reports/evidence/2026-10-29-reset-retry-control');sha=lambda x:hashlib.sha256(x).hexdigest()
for n,h in json.loads((r/'media-raw-identity.json').read_text()).items():assert sha((r/'media'/n).read_bytes())==h
source=json.loads((r/'source-identity.json').read_text())
for p,h in source.items():assert sha(Path(p).read_bytes())==h,p
built=json.loads((r/'native-build-source-identity.json').read_text());assert all(source.get(p)==h for p,h in built.items())
assert len(source)==len(built)+2
products=Path('/private/tmp/yl-reset-retry-control/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((r/'binary-identity.json').read_text())
base=json.loads(subprocess.check_output(['git','show','e4c93978:tool/release_readiness/inventory.json']));cur=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(cur['rows'])==102
changed=[p for p,h in base['source']['files'].items() if cur['source']['files'].get(p)!=h];assert changed==['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift'],changed
prod=Path(changed[0]);oldprod=subprocess.check_output(['git','show','e4c93978:'+str(prod)]).decode();assert prod.read_text()==oldprod.replace('v7 sources: 0 not an error,','v7 sources: 0 no recorded cancellation error,')
for name in ['tool/playback_network/abr_accesslog.py','tool/playback_network/proxy_boundaries.py','tool/playback_network/budget_exhaustion.py','packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlDashAutoRecoveryPolicy.swift']:
 assert Path(name).read_bytes()==subprocess.check_output(['git','show','e4c93978:'+name])
for a,b in zip(base['rows'],cur['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
 assert len(b['evidence'])==len(set(b['evidence']))<=20
assert all(cur['evidence'][k]==v for k,v in base['evidence'].items())
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==5 and a['sameBinary'] and not a['capabilityAccepted'] and not a['continuityAccepted'] and not a['physicalOutputVerified']
executions=json.loads((r/'media/results.json').read_text());assert len(executions)==5
for n,d in a['results'].items():
 summary=json.loads((r/'media'/(n+'-summary.json')).read_text());assert summary['totalTestCount']==1 and summary['skippedTests']==0 and summary['passedTests']==(0 if d['nativeExitCode'] else 1) and summary['failedTests']==(1 if d['nativeExitCode'] else 0)
 execution=next(x for x in executions if x['name']==n);assert execution['exitCode']==(0 if d['receiptPassed'] else 1)
 receipt=json.loads((r/'media'/n/'receipt.json').read_text());assert receipt['exitCode']==d['nativeExitCode'];assert receipt['passed']==d['receiptPassed'] and receipt['binaryHashes']==binary and receipt['ownedProcessExited'] and receipt['binaryIdentityUnchanged']
 assert not d['continuity']['continuityAccepted'] and not d['continuity']['physicalOutputVerified'] and not d['continuity']['audioSynchronizationVerified']
 assert receipt['passed']==d['reassessmentPassed']
 if n.startswith('budget-') and d['budget']:assert receipt['budgetExhaustionObservation']==d['budget'] and d['budget']['maximumAttempts']==2 and not d['budget']['thirdReservationObserved']
 assert not d['signals']
for platform,c in [('ios',256),('macos',231)]:
 d=json.loads((r/(platform+'-final-summary.json')).read_text());assert d['passedTests']==d['totalTestCount']==c and d['failedTests']==d['skippedTests']==0
 assert json.loads((r/(platform+'-final-result.json')).read_text())['exitCode']==0
replay=json.loads((r/'byte-replay/results.json').read_text());assert len(replay)==6 and sum(v['oldPassed'] for v in replay.values())==3
for name,d in replay.items():
 root=Path(d['archiveRoot'])
 for n,h in d['originalRawHashes'].items():
  p=root/n;data=p.read_bytes() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes());assert sha(data)==h
history=json.loads((r/'history.json').read_text());assert len(history)==49
for row in history:
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256']
 assert p.read_bytes()==subprocess.check_output(['git','show','e4c93978:'+str(p)])
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
assert 'Ran 206 tests' in (r/'tools.log').read_text() and '\nOK\n' in (r/'tools.log').read_text()
assert 'Ran 46 tests' in (r/'consumer.log').read_text() and 'OK (skipped=1)' in (r/'consumer.log').read_text()
assert all(x['exitCode']==0 for x in json.loads((r/'offline-results.json').read_text()))
assert all(v['exitCode']==v['expected'] for v in json.loads((r/'readiness-results.json').read_text()))
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
e=cur['evidence']['reset-retry-control-20261029'];assert sha(Path(e['path']).read_bytes())==e['sha256']
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
assert bundles==7,bundles
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
print(json.dumps(dict(completeXcresults=bundles,newNative=dict(ios=256,macos=231),sourceFiles=len(source),binaryFiles=len(binary),newLongMediaRuns=5,strictPasses=a['strictPasses'],reassessedPasses=a['reassessedPasses'],historicalGroups=49,historicalHashEntries=sum(x['files'] for x in history),ledgerStatusesUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
