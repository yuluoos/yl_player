from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-connection-persistence');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-connection-persistence');sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==432;assert all(sha(Path(p).read_bytes())==h for p,h in identity.items())
capture=json.loads((r/'capture-source-identity.json').read_text());assert [p for p in identity if capture[p]!=identity[p]]==['tool/playback_network/test_network_profile.py']
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
base=json.loads(subprocess.check_output(['git','show','ac482e57:tool/release_readiness/inventory.json']));current=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert base['source']==current['source'];assert len(current['rows'])==102
for a,b in zip(base['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert all(base['evidence'][k]==current['evidence'][k] for k in base['evidence'])
a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==3 and a['finalPassed']==2 and a['sameBinaryWithinEachStage'];assert all(q['attempts']==0 and q['proxySummary']['fullyCorrelated'] for q in a['results'].values());assert a['results']['http11-close']['nativeExitCode']==65 and a['results']['http11-close']['hostFailureCount']==1
assert a['matchedHTTP11Cohort']['summary']['http11-keepalive']['connectSeconds'] is None
for q in json.loads((r/'restored-merge-logs.json').read_text()):assert sha(Path(q['path']).read_bytes())==q['sha256']
ledger=json.loads((r/'ledger.stdout').read_text());assert ledger['sourceMatches'] and not ledger['releaseReady']
print(json.dumps(dict(sourceFiles=432,completeXcresults=3,rawRecords=len(records),diagnosticPasses=2,nativeFailures=1,automaticAttempts=0,restoredHistoricalLogs=7,sourceMatches=True,releaseReady=False),indent=2))
