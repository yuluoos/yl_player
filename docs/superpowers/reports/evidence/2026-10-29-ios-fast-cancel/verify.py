from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-fast-cancel');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-fast-cancel');sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==438 and all(sha(Path(p).read_bytes())==h for p,h in identity.items());assert identity==json.loads((r/'capture-source-identity.json').read_text())
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
assert bundles==8
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
base=json.loads(subprocess.check_output(['git','show','bffe50ea:tool/release_readiness/inventory.json']));current=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(current['rows'])==102 and current['source']==json.loads((r/'production-source.json').read_text())
for a,b in zip(base['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(base['evidence'][k]==current['evidence'][k] for k in base['evidence'])
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==4 and a['sameBinary'];assert all(not q['continuity']['continuityAccepted'] for q in a['results'].values())
for n,q in a['results'].items():
 d=json.loads((r/'media'/n/'receipt.json').read_text());assert d['passed']==q['receiptPassed'] and d['exitCode']==q['nativeExitCode'] and d['binaryHashes']==json.loads((r/'binary-identity.json').read_text()) and d['connectionLifecycleObservation']==q['lifecycle']
 x=json.loads((r/'media'/(n+'-summary.json')).read_text());assert x['totalTestCount']==1
 if d['exitCode']==0:assert x['passedTests']==1 and x['failedTests']==x['skippedTests']==0
for platform,count in [('ios',249),('macos',224)]:
 d=json.loads((r/(platform+'-binding/case-identities.json')).read_text())['summary'];assert d['passedTests']==d['totalTestCount']==count and d['failedTests']==d['skippedTests']==0
assert json.loads((r/'cause-red-result.json').read_text())['exitCode']==65
prior=json.loads((r/'prior-evidence.json').read_text());assert len(prior)==36
for row in prior:
 root=Path('docs/superpowers/reports/evidence')/row['group'];manifest=root/'SHA256SUMS';assert sha(manifest.read_bytes())==row['manifestSha256']
 for line in manifest.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((root/n).read_bytes())==h
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady'];assert all(x['exitCode']==x['expected'] for x in json.loads((r/'readiness-results.json').read_text()))
print(json.dumps(dict(sourceFiles=438,nativeContracts={'ios':249,'macos':224},completeXcresults=bundles,rawRecords=len(records),totalMediaRuns=4,strictMediaPasses=a['strictPasses'],reassessedPasses=a['reassessedPasses'],priorGroups=len(prior),priorHashEntries=sum(q['files'] for q in prior),ledgerRowsUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
