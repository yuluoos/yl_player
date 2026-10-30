from pathlib import Path
import hashlib,json,subprocess,gzip,tarfile,sys
r=Path('/private/tmp/yl-timeout-overflow');out=Path('docs/superpowers/reports/evidence/2026-10-29-native-timeout-overflow');sha=lambda x:hashlib.sha256(x).hexdigest()
source=json.loads((r/'source-identity.json').read_text())
for p,h in source.items():assert sha(Path(p).read_bytes())==h,p
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((r/'binary-identity.json').read_text())
base=json.loads(subprocess.check_output(['git','show','9658ac6a:tool/release_readiness/inventory.json']));cur=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(cur['rows'])==102
for a,b in zip(base['rows'],cur['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(cur['evidence'][k]==v for k,v in base['evidence'].items())
changed=[p for p in set(base['source']['files'])|set(cur['source']['files']) if base['source']['files'].get(p)!=cur['source']['files'].get(p)]
assert sorted(Path(p).name for p in changed)==['YlHlsMediaProxy.swift','YlHlsResourceLoader.swift']
for platform,c in [('ios',254),('macos',229)]:
 name=platform+'-final';s=json.loads((r/(name+'-summary.json')).read_text());assert s['totalTestCount']==s['passedTests']==c and s['failedTests']==s['skippedTests']==0
 b=json.loads((r/(platform+'-binding/case-identities.json')).read_text());assert b['expected']==b['observed']
 assert all(b['summary'][k]==s[k] for k in ('totalTestCount','passedTests','failedTests','skippedTests'))
 assert json.loads((r/(name+'-result.json')).read_text())['exitCode']==0
assert json.loads((r/'native-probe-red-result.json').read_text())['exitCode']==65
red=json.loads((r/'native-probe-red-summary.json').read_text());assert red['failedTests']==red['totalTestCount']==1 and 'Crash' in red['testFailures'][0]['failureText']
assert json.loads((r/'native-probe-green-result.json').read_text())['exitCode']==0
assert json.loads((r/'native-probe-green-summary.json').read_text())['passedTests']==1
assert json.loads((r/'ios-build-result.json').read_text())['exitCode']==0
initial=json.loads((r/'offline-results.json').read_text());assert [x['exitCode'] for x in initial]==[1,0,0]
assert 'FAILED (errors=18)' in (r/'tools.log').read_text()
assert 'Ran 200 tests' in (r/'tools-final.log').read_text() and '\nOK\n' in (r/'tools-final.log').read_text()
assert json.loads((r/'tools-final-result.json').read_text())['exitCode']==0
assert 'Ran 46 tests' in (r/'consumer.log').read_text() and 'OK (skipped=1)' in (r/'consumer.log').read_text()
assert 'iOS 881, macOS 925 verified' in (r/'registry.log').read_text()
history=json.loads((r/'history.json').read_text());assert len(history)==45
for row in history:
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256']
 assert p.read_bytes()==subprocess.check_output(['git','show','9658ac6a:'+str(p)])
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
replay=json.loads((r/'byte-replay/results.json').read_text());assert len(replay)==6 and sum(v['oldPassed'] for v in replay.values())==3
for name,d in replay.items():
 root=Path('/private/tmp')/name.split('/')[0]/'media'/name.split('/')[1]
 for n,h in d['originalRawHashes'].items():assert sha((root/n).read_bytes())==h
assert all(v['exitCode']==v['expected'] for v in json.loads((r/'readiness-results.json').read_text()))
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
e=cur['evidence']['native-timeout-overflow-20261029'];assert sha(Path(e['path']).read_bytes())==e['sha256']
assert (r/'review-final.md').exists()
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
assert bundles==4
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
print(json.dumps(dict(completeXcresults=bundles,selectedNative={'ios':254,'macos':229},sourceFiles=len(source),binaryFiles=len(binary),newLongMediaRuns=0,historicalGroups=45,historicalHashEntries=sum(x['files'] for x in history),ledgerStatusesUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
