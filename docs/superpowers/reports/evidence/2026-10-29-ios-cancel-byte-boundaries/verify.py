from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-cancel-byte-boundaries');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-cancel-byte-boundaries');sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==438 and all(sha(Path(p).read_bytes())==h for p,h in identity.items());assert identity==json.loads((r/'capture-source-identity.json').read_text())
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((r/'binary-identity.json').read_text()) and len(binary)==307
records=json.loads((out/'raw-provenance.json').read_text());bundles=[]
for row in records:
 if 'archiveParts' in row:
  bundles.append(row['source']);temp=r/'verify-bundle.tar.gz';digest=hashlib.sha256()
  with temp.open('wb') as f:
   for part in row['archiveParts']:
    data=(out/part['path']).read_bytes();assert sha(data)==part['sha256'];digest.update(data);f.write(data)
  assert digest.hexdigest()==row['archiveSha256']
  with tarfile.open(temp,'r:gz') as tar:files={str(Path(m.name).relative_to(row['source'])):sha(tar.extractfile(m).read()) for m in tar.getmembers() if m.isfile()}
  assert files==row['bundleFiles'];temp.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256'];original=gzip.decompress(data) if row['compressed'] else data;assert sha(original)==row['sourceSha256']==sha((r/row['source']).read_bytes())
assert len(bundles)==7 and sum('media-incomplete-at-resume' in n for n in bundles)==1
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
base=json.loads(subprocess.check_output(['git','show','524f31a0:tool/release_readiness/inventory.json']));current=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(current['rows'])==102 and current['source']==base['source']==json.loads((r/'production-source.json').read_text())
for a,b in zip(base['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(base['evidence'][k]==current['evidence'][k] for k in base['evidence'])
for row in current['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':assert len(row['evidence'])==20
for evidence in current['evidence'].values():
 if evidence.get('kind')=='report' and 'path' in evidence:assert sha(Path(evidence['path']).read_bytes())==evidence['sha256']
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2 and a['sameBinary'];assert all(not q['continuity']['continuityAccepted'] for q in a['results'].values())
for n,q in a['results'].items():
 d=json.loads((r/'media'/n/'receipt.json').read_text());assert d['passed']==q['receiptPassed']==q['reassessmentPassed'] and d['exitCode']==q['nativeExitCode'] and d['binaryHashes']==binary and d['connectionLifecycleObservation']==q['lifecycle']
 x=json.loads((r/'media'/(n+'-summary.json')).read_text());assert x['totalTestCount']==1
 if d['exitCode']==0:assert x['passedTests']==1 and x['failedTests']==x['skippedTests']==0
for platform,count in [('ios',252),('macos',227)]:
 d=json.loads((r/(platform+'-binding/case-identities.json')).read_text())['summary'];assert d['passedTests']==d['totalTestCount']==count and d['failedTests']==d['skippedTests']==0
assert json.loads((r/'native-probe-fixed-result.json').read_text())['exitCode']==0
assert json.loads((r/'native-probe-result.json').read_text())['exitCode']==65
probes=json.loads((r/'probe-analysis.json').read_text());assert len(probes)==7
for v in probes.values():
 assert not v['capabilityAccepted']
 for sample in v['samples']:assert sample['trace']['metrics']['version']==3 and not sample['capabilityAccepted']
for run in ('ios-final','macos-final'):
 forced=probes[run+'/forced']['samples'][0];assert len(forced['matchedServerParseIndices'])==2 and forced['metrics']['transactionCount']==2 and not forced['metrics']['complete']
 for sample in probes[run+'/unoccupied']['samples']:
  trace=sample['trace'];followup=sample['followupTrace'];assert trace['resourceToken']==followup['resourceToken'] and trace['correlationID']!=followup['correlationID'] and followup['correlationID'] in sample['parsedServerTraceIDs']
legacy=json.loads((r/'legacy-replay/replay-results.json').read_text());assert len(legacy)==4 and sum(v['newPassed'] for v in legacy.values())==2
for n,v in legacy.items():assert v['newPassed']==v['oldPassed'] and v['rawHashesUnchanged']
replay=json.loads((r/'byte-replay/results.json').read_text());assert len(replay)==6 and sum(v['oldPassed'] for v in replay.values())==3
for name,v in replay.items():
 root=Path('/private/tmp')/name.split('/')[0]/'media'/name.split('/')[1]
 for path,h in v['originalRawHashes'].items():assert sha((root/path).read_bytes())==h
assert 'Ran 200 tests' in (r/'tools-final.log').read_text() and '\nOK\n' in (r/'tools-final.log').read_text()
assert 'Ran 46 tests' in (r/'consumer-final.log').read_text() and 'OK (skipped=1)' in (r/'consumer-final.log').read_text()
prior=json.loads((r/'prior-evidence.json').read_text());assert len(prior)==42
for row in prior:
 root=Path('docs/superpowers/reports/evidence')/row['group'];manifest=root/'SHA256SUMS';assert sha(manifest.read_bytes())==row['manifestSha256']
 for line in manifest.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((root/n).read_bytes())==h
incomplete=json.loads((r/'incomplete-at-resume.json').read_text());assert not incomplete['accepted'] and not incomplete['receiptPresent']
for path,h in incomplete['files'].items():assert sha((r/incomplete['directory']/path).read_bytes())==h
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady'];assert all(x['exitCode']==x['expected'] for x in json.loads((r/'readiness-results.json').read_text()))
print(json.dumps(dict(sourceFiles=438,binaryFiles=307,nativeContracts={'ios':252,'macos':227},completeXcresults=6,incompleteXcresultDirectories=1,rawRecords=len(records),completedMediaRuns=2,strictMediaPasses=a['strictPasses'],reassessedPasses=a['reassessedPasses'],priorGroups=len(prior),priorHashEntries=sum(q['files'] for q in prior),ledgerRowsUnchanged=102,sourceMatches=True,releaseReady=False),indent=2))
