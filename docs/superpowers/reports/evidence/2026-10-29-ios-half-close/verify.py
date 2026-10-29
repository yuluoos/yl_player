from pathlib import Path
import json,hashlib,gzip,tarfile,subprocess
r=Path('/private/tmp/yl-half-close');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-half-close');sha=lambda b:hashlib.sha256(b).hexdigest()
for p,h in json.loads((r/'source-identity.json').read_text()).items():assert sha(Path(p).read_bytes())==h
base=json.loads(subprocess.check_output(['git','show','2e3e2793:tool/release_readiness/inventory.json']));d=json.loads(Path('tool/release_readiness/inventory.json').read_text());assert base['source']==d['source']
for a,b in zip(base['rows'],d['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
assert len(d['rows'])==102 and all(d['evidence'][k]==v for k,v in base['evidence'].items())
for n,c in [('ios-final',253),('macos-final',228),('ios-confirm',1),('macos-confirm',1)]:
 q=json.loads((r/(n+'-summary.json')).read_text());assert q['passedTests']==q['totalTestCount']==c and q['failedTests']==q['skippedTests']==0
obs=json.loads((r/'observations.json').read_text());assert len(obs)==4
for v in obs.values():
 assert v['observations'][0]['receivedExpectedBody'] and not v['observations'][1]['receivedExpectedBody'] and v['traces'][0]['cancelCause']==2 and not v['halfCloseSupportAccepted'] and not v['historicalCauseProven']
assert 'Ran 200 tests' in (r/'tools.log').read_text() and '\nOK\n' in (r/'tools.log').read_text()
assert 'OK (skipped=1)' in (r/'consumer-confirm.log').read_text()
for row in json.loads((r/'history.json').read_text()):
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256']
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
bundles=0
for row in json.loads((out/'raw-provenance.json').read_text()):
 if 'archiveParts' in row:
  bundles+=1;p=r/'verify.tar.gz';content=b''.join((out/v['path']).read_bytes() for v in row['archiveParts']);assert sha(content)==row['archiveSha256'];p.write_bytes(content)
  with tarfile.open(p,'r:gz') as t:actual={str(Path(m.name).relative_to(row['source'])):sha(t.extractfile(m).read()) for m in t.getmembers() if m.isfile()}
  assert actual==row['bundleFiles'];p.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256'];assert sha(gzip.decompress(data) if row['compressed'] else data)==row['sourceSha256']==sha((r/row['source']).read_bytes())
assert bundles==4
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
assert all(v['exitCode']==v['expected'] for v in json.loads((r/'readiness-results.json').read_text()))
q=json.loads((r/'ledger.stdout').read_text());assert q['sourceMatches'] and not q['releaseReady']
print(json.dumps(dict(completeXcresults=bundles,selectedNative={'ios':253,'macos':228},finalDirected={'ios':1,'macos':1},historyGroups=43,productionSourceUnchanged=True,releaseReady=False,halfCloseSupportAccepted=False,historicalCauseProven=False),indent=2))
