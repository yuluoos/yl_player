from pathlib import Path
import json,hashlib,tarfile,gzip,io,subprocess
base=Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-races');raw=Path('/private/tmp/yl-production-races');sha=lambda b:hashlib.sha256(b).hexdigest()
lines=(base/'SHA256SUMS').read_text().splitlines()
for line in lines:
 h,p=line.split('  ',1);assert sha((base/p).read_bytes())==h,p
records=json.loads((base/'raw-provenance.json').read_text());bundles=[]
for r in records:
 path=base/r['archive']
 if 'bundleFiles' in r:
  if 'archiveParts' in r:
   data=b''.join((base/p['path']).read_bytes() for p in r['archiveParts']);assert sha(data)==r['archiveSha256'];t=tarfile.open(fileobj=io.BytesIO(data),mode='r:gz')
  else:
   assert sha(path.read_bytes())==r['archiveSha256'];t=tarfile.open(path,'r:gz')
  original=raw/r['source'];expected={str(p.relative_to(original.parent)):sha(p.read_bytes()) for p in original.rglob('*') if p.is_file()}
  with t:actual={m.name:sha(t.extractfile(m).read()) for m in t.getmembers() if m.isfile()}
  assert actual==expected and len(actual)==r['bundleFiles'],r['source'];bundles.append(r['source'])
 else:
  data=path.read_bytes();assert sha(data)==r['archiveSha256'];data=gzip.decompress(data) if path.name.endswith('.gz') else data;assert sha(data)==r['sourceSha256']==sha((raw/r['source']).read_bytes()),r['source']
before=json.loads(subprocess.check_output(['git','show','942fc481:tool/release_readiness/inventory.json'],text=True));after=json.loads(Path('tool/release_readiness/inventory.json').read_text())
assert len(before['rows'])==len(after['rows'])==102
for a,b in zip(before['rows'],after['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
changes=sorted(p for p in set(before['source']['files']) | set(after['source']['files']) if before['source']['files'].get(p)!=after['source']['files'].get(p))
assert after['source']==json.loads((raw/'final-production-source.json').read_text())
assert changes==sorted(['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift','packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlApplePlayerHost.swift','packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlAppleSessionCoordinator.swift']),changes
result=dict(manifestEntriesVerified=len(lines),completeXcresultBundlesVerified=len(bundles),bundleFilesComparedToOriginal=bool(bundles),nativeContractEvidenceReused=False,newNativeMediaBundles=sum('media/' in b for b in bundles),rawProvenanceEntriesVerified=len(records),all102RowStatesUnchanged=True,changedProductionFiles=changes)
(base/'final-verification.json').write_text(json.dumps(result,indent=2)+'\n')
files=sorted(p for p in base.rglob('*') if p.is_file() and p.name!='SHA256SUMS');assert max(p.stat().st_size for p in files)<=16*1024*1024
(base/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(base))+'\n' for p in files))
print(result)
