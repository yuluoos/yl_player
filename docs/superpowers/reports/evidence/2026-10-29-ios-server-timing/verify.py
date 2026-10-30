from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-server-timing');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-server-timing');sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==434;assert all(sha(Path(p).read_bytes())==h for p,h in identity.items())
capture=json.loads((r/'capture-source-identity.json').read_text());assert capture==identity
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
assert bundles==3
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
base=json.loads(subprocess.check_output(['git','show','35819ab9:tool/release_readiness/inventory.json']));current=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert base['source']==current['source'];assert len(current['rows'])==102
for a,b in zip(base['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(base['evidence'][k]==current['evidence'][k] for k in base['evidence'])
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==3 and a['finalPassed']==3 and a['sameBinaryWithinEachStage'];assert all(q['attempts']==0 and q['proxySummary']['fullyCorrelated'] and q['hostFailureCount']==0 and not q['signals'] and not q['continuity']['continuityAccepted'] for q in a['results'].values())
for n,q in a['results'].items():
 receipt=json.loads((r/'media'/n/'receipt.json').read_text());assert receipt['passed'] and receipt['exitCode']==0 and receipt['serverTimingObservation']==q['serverTiming']
 x=json.loads((r/'media'/(n+'-summary.json')).read_text());assert x['passedTests']==1 and x['failedTests']==x['skippedTests']==0
 assert receipt['binaryHashes']==json.loads((r/'binary-reuse.json').read_text())['binaryHashes']
assert a['matchedHTTP11Cohort']['summary']['http11-close']['requestCount']==247
prior=json.loads((r/'prior-evidence.json').read_text());assert len(prior)==31 and sum(x['files'] for x in prior)==7411
for row in prior:
 root=Path('docs/superpowers/reports/evidence')/row['group'];manifest=root/'SHA256SUMS';assert sha(manifest.read_bytes())==row['manifestSha256']
 for line in manifest.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((root/n).read_bytes())==h
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
assert all(x['exitCode']==x['expected'] for x in json.loads((r/'readiness-results.json').read_text()))
print(json.dumps(dict(sourceFiles=434,completeXcresults=3,rawRecords=len(records),diagnosticPasses=3,nativeFailures=0,automaticAttempts=0,priorGroups=31,priorHashEntries=7411,ledgerRowsUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
