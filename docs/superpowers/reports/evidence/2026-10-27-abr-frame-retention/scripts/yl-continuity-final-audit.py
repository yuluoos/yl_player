from pathlib import Path
import json,hashlib,gzip,subprocess
root=Path.cwd();e=root/'docs/superpowers/reports/evidence/2026-10-27-abr-frame-retention'
sha=lambda b:hashlib.sha256(b).hexdigest()
p=e/'archive-provenance.json';prov=json.loads(p.read_text());prov['files']=[r for r in prov['files'] if not r['archive'].startswith('final-checks/')]
for f in Path('/private/tmp/yl-continuity-final-checks').iterdir():
 if not f.is_file():continue
 archive='final-checks/'+f.name+('.gz' if f.suffix=='.log' else '')
 prov['files'].append(dict(source=str(f),archive=archive,rawSha256=sha(f.read_bytes()),rawBytes=f.stat().st_size))
p.write_text(json.dumps(prov,indent=2)+'\n')
for r in prov['files']:
 b=(e/r['archive']).read_bytes()
 if r['archive'].endswith('.gz'):b=gzip.decompress(b)
 assert sha(b)==r['rawSha256'] and len(b)==r['rawBytes'],r['archive']
phases=[]
for run,phase in [('runs','source-simulator-phase'),('physical-initial','source-final'),('physical-retry','source-final'),('physical-controls','source-final')]:
 ids=json.loads((e/run/'source-identity.json').read_text())
 for name,expected in ids.items():
  file=e/phase/name
  b=file.read_bytes() if file.exists() else subprocess.check_output(['git','show','06fd55b4:'+name])
  assert sha(b)==expected,(run,name)
 phases.append(dict(run=run,sourcePhase=phase,files=len(ids),matched=True))
ledger=json.loads((e/'final-checks/ledger-final.log.gz').read_bytes() and gzip.decompress((e/'final-checks/ledger-final.log.gz').read_bytes()))
assert ledger['sourceMatches'] and not ledger['releaseReady'] and ledger['currentPasses']==0
assert not any('inventory-private' in str(f) or 'device-process-schema' in str(f) for f in e.rglob('*'))
manifest=[]
for f in sorted(e.rglob('*')):
 if f.is_file() and f.name not in ['SHA256SUMS','integrity.json']:
  manifest.append((str(f.relative_to(e)),sha(f.read_bytes())))
(e/'integrity.json').write_text(json.dumps(dict(rawArchiveEntriesVerified=len(prov['files']),phaseSourceBindings=phases,filesBeforeIntegrity=len(manifest),resultBundles=len(list((e/'xcresult').glob('*.tar.gz'))),sourceMatches=True,releaseReady=False,published=False),indent=2)+'\n')
manifest.append(('integrity.json',sha((e/'integrity.json').read_bytes())))
(e/'SHA256SUMS').write_text(''.join(h+'  '+name+'\n' for name,h in sorted(manifest)))
for name,h in manifest:assert sha((e/name).read_bytes())==h
print(json.dumps(dict(filesVerified=len(manifest),bundles=len(list((e/'xcresult').glob('*.tar.gz'))),rawEntries=len(prov['files']),phaseBindings=phases)))
