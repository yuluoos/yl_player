from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess,sys
r=Path('/private/tmp/yl-transaction-metrics');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-transaction-metrics')
sha=lambda b:hashlib.sha256(b).hexdigest()
identity=json.loads((r/'source-identity.json').read_text());assert len(identity)==414
assert all(sha(Path(p).read_bytes())==h for p,h in identity.items())
initial=json.loads((r/'initial-native-source-identity.json').read_text());diff=[p for p,h in initial.items() if identity[p]!=h];assert len(diff)==3,diff
records=json.loads((out/'raw-provenance.json').read_text());bundles=0
for row in records:
 if 'archiveParts' in row:
  bundles+=1;temp=r/'verify-bundle.tar.gz';digest=hashlib.sha256()
  with temp.open('wb') as f:
   for part in row['archiveParts']:
    data=(out/part['path']).read_bytes();assert sha(data)==part['sha256'];digest.update(data);f.write(data)
  assert digest.hexdigest()==row['archiveSha256']
  with tarfile.open(temp,'r:gz') as tar:
   files={str(Path(m.name).relative_to(row['source'])):sha(tar.extractfile(m).read()) for m in tar.getmembers() if m.isfile()}
  assert files==row['bundleFiles'];temp.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256']
  original=gzip.decompress(data) if row['compressed'] else data
  assert sha(original)==row['sourceSha256']==sha((r/row['source']).read_bytes())
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
baseline=json.loads(subprocess.check_output(['git','show','9a307e9c:tool/release_readiness/inventory.json']))
current=json.loads(Path('tool/release_readiness/inventory.json').read_text())
assert len(current['rows'])==102
for a,b in zip(baseline['rows'],current['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k],(a['requirement'],k)
assert set(baseline['evidence'])<=set(current['evidence'])
assert all(baseline['evidence'][k]==current['evidence'][k] for k in baseline['evidence'])
changed=[p for p,h in current['source']['files'].items() if baseline['source']['files'].get(p)!=h]
assert changed==['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift'],changed
analysis=json.loads((r/'analysis.json').read_text());assert analysis['totalRuns']==2 and analysis['sameBinaryWithinEachStage']
for n,count in [('final-macos',223),('final-device',248)]:
 d=json.loads((r/(n+'-summary.json')).read_text());assert d['passedTests']==count and d['failedTests']==d['skippedTests']==0
for n in ['final-original','final-recovery-control']:
 d=json.loads((r/'media'/n/'receipt.json').read_text());assert d['binaryIdentityUnchanged'] and d['ownedProcessExited'];assert d['proxyRequestObservation']['fullyCorrelated'] == (n=='final-original')
 assert d['passed'] is False
readiness=json.loads((r/'ledger.stdout').read_text());assert readiness['sourceMatches'] and not readiness['releaseReady']
print(json.dumps(dict(sourceFiles=len(identity),changedFinalNativeInputs=diff,rawRecords=len(records),completeXcresults=bundles,ledgerRows=102,sourceMatches=True,releaseReady=False),indent=2))
