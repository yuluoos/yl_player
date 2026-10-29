from pathlib import Path
import json,hashlib,gzip,tarfile,io,subprocess
raw=Path('/private/tmp/yl-request-timing');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-request-timing');sha=lambda data:hashlib.sha256(data).hexdigest()
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h,n
records=json.loads((out/'raw-provenance.json').read_text());bundles=0
for r in records:
 if 'bundleFiles' in r:
  blobs=[(out/p['path']).read_bytes() for p in r['archiveParts']]
  for p,b in zip(r['archiveParts'],blobs):assert sha(b)==p['sha256']
  data=b''.join(blobs);assert sha(data)==r['archiveSha256']
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as t:actual={str(Path(m.name).relative_to(r['source'])):sha(t.extractfile(m).read()) for m in t.getmembers() if m.isfile()}
  expected={str(p.relative_to(raw/r['source'])):sha(p.read_bytes()) for p in (raw/r['source']).rglob('*') if p.is_file()}
  assert actual==r['bundleFiles']==expected;bundles+=1
 else:
  data=(out/r['archive']).read_bytes();assert sha(data)==r['archiveSha256']
  if r['compressed']:data=gzip.decompress(data)
  assert sha(data)==r['sourceSha256']==sha((raw/r['source']).read_bytes()),r['source']
identity=json.loads((raw/'source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
initial=json.loads((raw/'initial-source-identity.json').read_text());assert len(initial)==len(identity)==412
assert len([p for p in initial if initial[p]!=identity[p]])==10
before=json.loads(subprocess.check_output(['git','show','91ecf8f9:tool/release_readiness/inventory.json'],text=True));after=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert len(before['rows'])==len(after['rows'])==102
for a,b in zip(before['rows'],after['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert after['source']==json.loads((raw/'final-production-source.json').read_text())
changed=[p for p,h in after['source']['files'].items() if before['source']['files'].get(p)!=h]
assert len(changed)==1 and changed[0].endswith('/YlHlsMediaProxy.swift')
analysis=json.loads((raw/'analysis.json').read_text());assert analysis['sameBinaryWithinEachStage'] and analysis['totalRuns']==5 and analysis['finalRuns']==2 and analysis['finalPassed']==1
assert analysis['results']['reviewed-recovery-control']['originalReceiptPassed'] and not analysis['results']['reviewed-recovery-control']['finalReassessmentPassed']
for name in ['final-original','final-recovery-control']:assert analysis['results'][name]['proxySummary']['fullyCorrelated']
binding=json.loads((raw/'final-native-binding.json').read_text());assert binding['sourceFilesVerified']==412
assert binding['scope']['macos']['passed']==222 and binding['scope']['device']['passed']==247
result=dict(rawProvenanceRecordsVerified=len(records),completeBundlesVerified=bundles,bundleFilesComparedToOriginal=True,finalSourceFilesVerified=len(identity),preReviewSourceDifferences=10,all102RowStatesUnchanged=True,changedProductionFiles=changed,allFiveRunsRetained=True,finalRuns=2,finalStrictPassed=1,originalFailureRetained=True,preReviewControlReassessedAsIncomplete=True)
(out/'final-verification.json').write_text(json.dumps(result,indent=2)+'\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS');(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files));print(result)
