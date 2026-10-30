from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-failure-observations');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-failure-observations');sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==438; capture=json.loads((r/'capture-source-identity.json').read_text()); trim=json.loads((r/'post-capture-whitespace.json').read_text()); assert [p for p in identity if identity[p]!=capture[p]]==[trim['path']]; assert capture[trim['path']]==trim['before'] and identity[trim['path']]==trim['after']; assert (r/'pretrim-test-bandwidth.py.txt').read_bytes()==Path(trim['path']).read_bytes()+b'\n';assert all(sha(Path(p).read_bytes())==h for p,h in identity.items())
reuse=json.loads((r/'reuse-identity.json').read_text());assert reuse['unchangedNativeInputs'] and reuse['unchangedBinary'] and reuse['binaryFiles']==307 and reuse['notRerun']
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((r/'binary-identity.json').read_text())
records=json.loads((out/'raw-provenance.json').read_text());bundles=0
for row in records:
 if 'archiveParts' in row:
  bundles+=1;temp=r/'verify-bundle.tar.gz';digest=hashlib.sha256()
  with temp.open('wb') as f:
   for part in row['archiveParts']:
    data=(out/part['path']).read_bytes();assert sha(data)==part['sha256'];digest.update(data);f.write(data)
  assert digest.hexdigest()==row['archiveSha256']
  with tarfile.open(temp,'r:gz') as tar:files={str(Path(m.name).relative_to(row['source'])):sha(tar.extractfile(m).read()) for m in tar.getmembers() if m.isfile()}
  assert files==row['bundleFiles'];temp.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256'];original=gzip.decompress(data) if row['compressed'] else data;assert sha(original)==row['sourceSha256']==sha((r/row['source']).read_bytes())
assert bundles==2
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
base=json.loads(subprocess.check_output(['git','show','66d12aa3:tool/release_readiness/inventory.json']));current=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(current['rows'])==102 and current['source']==base['source']==json.loads((r/'production-source.json').read_text())
for a,b in zip(base['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(base['evidence'][k]==current['evidence'][k] for k in base['evidence'])
replay=json.loads((r/'replay-results.json').read_text());assert len(replay)==4 and sum(v['newPassed'] for v in replay.values())==2
for n,v in replay.items():
 assert v['oldPassed']==v['newPassed'] and v['framesRetained'] and v['rawHashesUnchanged'];d=json.loads((r/(n+'-reanalysis.json')).read_text())
 for name,h in d['originalRawHashesUnchanged'].items():assert sha((Path('/private/tmp/yl-same-resource-retry/media')/n/name).read_bytes())==h
 assert not d['continuityObservation']['continuityAccepted'] and bool(v['cliExit'])==bool(v['errors'])
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2 and a['sameBinary']
for n,v in a['results'].items():
 d=json.loads((r/'media'/n/'receipt.json').read_text());assert v['receiptPassed']==d['passed'] and d['binaryHashes']==binary and d['continuityObservation']==v['continuity'] and not v['continuity']['continuityAccepted'];assert v['reassessmentPassed']==v['receiptPassed']
 summary=json.loads((r/'media'/(n+'-summary.json')).read_text());assert summary['totalTestCount']==1
 if d['exitCode']==0:assert summary['passedTests']==1 and summary['failedTests']==summary['skippedTests']==0
prior=json.loads((r/'prior-evidence.json').read_text());assert len(prior)==40
for v in prior:
 root=Path('docs/superpowers/reports/evidence')/v['group'];assert sha((root/'SHA256SUMS').read_bytes())==v['manifestSha256']
 for line in (root/'SHA256SUMS').read_text().splitlines():
  h,n=line.split('  ',1);assert sha((root/n).read_bytes())==h
assert 'Ran 195 tests' in (r/'tools-final.log').read_text() and '\nOK\n' in (r/'tools-final.log').read_text()
assert 'Ran 46 tests' in (r/'consumer-final.log').read_text() and 'OK (skipped=1)' in (r/'consumer-final.log').read_text()
checks=json.loads((r/'readiness-results.json').read_text());assert all(v['exitCode']==v['expected'] for v in checks)
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
print(json.dumps(dict(sourceFiles=len(identity),unchangedBinaryFiles=len(binary),nativeMatricesReused=True,toolTests=195,consumerPassed=45,consumerSkipped=1,completeNewXcresults=bundles,rawRecords=len(records),oldReanalysisPassed=2,oldReanalysisTotal=4,newMediaPassed=a['strictPasses'],newMediaTotal=2,priorGroups=len(prior),priorHashEntries=sum(v['files'] for v in prior),ledgerRowsUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
