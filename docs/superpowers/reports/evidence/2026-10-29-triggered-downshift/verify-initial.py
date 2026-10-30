from pathlib import Path
import json,hashlib,subprocess,gzip,tarfile,ast
r=Path('/private/tmp/yl-triggered-downshift');out=Path('docs/superpowers/reports/evidence/2026-10-29-triggered-downshift');sha=lambda d:hashlib.sha256(d).hexdigest();read=lambda p:json.loads(Path(p).read_text())
source=read(r/'source-identity.json');captured=read(r/'capture-source-identity.json');assert len(source)==len(captured)==442
for p,h in source.items():assert sha(Path(p).read_bytes())==h,p
changes=[p for p in source if source[p]!=captured[p]];assert sorted(changes)==sorted(read(r/'post-capture-validation-changes.json')['changed'])
for p in changes:assert sha((r/'capture-source-files'/p).read_bytes())==captured[p]
assert all(source[p]==h for p,h in captured.items() if p.endswith('.swift'))
for p,h in read(r/'media-raw-identity.json').items():assert sha((r/'media'/p).read_bytes())==h
products=r/'ios-build/Build/Products';binary={str(p.relative_to(products)):sha(p.read_bytes()) for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==read(r/'binary-identity.json') and len(binary)==307
base=json.loads(subprocess.check_output(['git','show','c7342f8c:tool/release_readiness/inventory.json']));cur=read('tool/release_readiness/inventory.json');assert base['source']==cur['source']==read(r/'production-source.json')
assert len(cur['rows'])==102 and all(cur['evidence'][k]==v for k,v in base['evidence'].items())
for a,b in zip(base['rows'],cur['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
 assert len(b['evidence'])==len(set(b['evidence']))<=20
for p,h in cur['source']['files'].items():assert sha(Path(p).read_bytes())==h,p
for name in ['tool/playback_network/budget_exhaustion.py','tool/playback_network/proxy_boundaries.py','tool/playback_network/transaction_metrics.py']:
 assert Path(name).read_bytes()==subprocess.check_output(['git','show','c7342f8c:'+name])
def functions(text):
 return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(text).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
oldfunctions=functions(subprocess.check_output(['git','show','c7342f8c:tool/playback_network/abr_accesslog.py']).decode());newfunctions=functions(Path('tool/playback_network/abr_accesslog.py').read_text())
assert all(newfunctions[k]==v for k,v in oldfunctions.items() if k not in ['run','main'])
a=read(r/'analysis.json');assert a['totalRuns']==3 and a['strictPasses']==a['reassessedPasses']==0
assert a['sameBinary'] and not a['capabilityAccepted'] and not a['continuityAccepted'] and not a['physicalOutputVerified']
for n,d in a['results'].items():
 receipt=read(r/'media'/n/'receipt.json');assert receipt['binaryHashes']==binary and receipt['binaryIdentityUnchanged'] and receipt['ownedProcessExited'] and not receipt['passed'];assert d['trigger']['bound'] and d['trigger']['secondDownshiftElapsed']>d['trigger']['trigger']['evidence']['elapsed']
 assert receipt['exitCode']==d['nativeExitCode'] and d['receiptPassed']==d['reassessmentPassed']
 summary=read(r/'media'/(n+'-summary.json'));assert summary['totalTestCount']==1 and summary['skippedTests']==0 and summary['passedTests']==int(d['nativeExitCode']==0) and summary['failedTests']==int(d['nativeExitCode']!=0)
 assert not d['continuity']['continuityAccepted'] and not d['continuity']['physicalOutputVerified'] and not d['continuity']['audioSynchronizationVerified']
 if n=='budget-zero':assert d['signals'] and d['nativeExitCode']==65 and not d['final']['completed']
 else:assert not d['signals'] and d['nativeExitCode']==0 and d['final']['completed']
 assert d['final']['automaticAttempts']==2
assert a['results']['budget-zero-repeat']['budget']==read(r/'media/budget-zero-repeat/receipt.json')['budgetExhaustionObservation']
assert a['results']['budget-zero-repeat']['final']['width']==320
assert a['results']['normal-zero']['final']['width']==640 and a['results']['normal-zero']['secondInstallProof']['stableHighTail']
for platform,count in [('ios',257),('macos',232)]:
 d=read(r/(platform+'-final-summary.json'));assert d['totalTestCount']==d['passedTests']==count and d['failedTests']==d['skippedTests']==0
 assert read(r/(platform+'-final-result.json'))['exitCode']==0
for row in read(r/'history.json'):
 p=Path('docs/superpowers/reports/evidence')/row['group']/'SHA256SUMS';assert sha(p.read_bytes())==row['manifestSha256'] and p.read_bytes()==subprocess.check_output(['git','show','c7342f8c:'+str(p)])
 for line in p.read_text().splitlines():
  h,n=line.split('  ',1);assert sha((p.parent/n).read_bytes())==h
history=read(r/'history.json');assert len(history)==50 and sum(v['files'] for v in history)==10531
assert 'Ran 211 tests' in (r/'tools.log').read_text() and '\nOK\n' in (r/'tools.log').read_text()
assert 'Ran 46 tests' in (r/'consumer.log').read_text() and 'OK (skipped=1)' in (r/'consumer.log').read_text()
assert all(v['exitCode']==0 for v in read(r/'offline-results.json'))
assert all(v['exitCode']==v['expected'] for v in read(r/'readiness-results.json'))
ledger=read(r/'ledger.stdout');assert ledger['sourceMatches'] and not ledger['releaseReady']
report=cur['evidence']['triggered-downshift-20261029'];assert sha(Path(report['path']).read_bytes())==report['sha256']
assert read(r/'rejected-profile-command.json')['exitCode']==1 and (r/'rejected-profile/receipt.json').exists() and not (r/'rejected-profile/probe.xctestrun').exists()
assert all(v['exitCode']==0 and v['metrics']['sessionInvalidated'] for v in read(r/'preparse-probe-results.json'))
records=read(out/'raw-provenance.json');assert any(v['source']=='review-final.md' for v in records);bundles=0
for row in records:
 if 'archiveParts' in row:
  bundles+=1;temp=r/'verify.tar.gz';digest=hashlib.sha256()
  with temp.open('wb') as f:
   for part in row['archiveParts']:
    data=(out/part['path']).read_bytes();assert sha(data)==part['sha256'];digest.update(data);f.write(data)
  assert digest.hexdigest()==row['archiveSha256']
  with tarfile.open(temp,'r:gz') as t:actual={str(Path(m.name).relative_to(row['source'])):sha(t.extractfile(m).read()) for m in t.getmembers() if m.isfile()}
  assert actual==row['bundleFiles'];temp.unlink()
 else:
  data=(out/row['archive']).read_bytes();assert sha(data)==row['archiveSha256'];assert sha(gzip.decompress(data) if row['compressed'] else data)==row['sourceSha256']==sha((r/row['source']).read_bytes())
assert bundles==5
for line in (out/'SHA256SUMS').read_text().splitlines():
 h,n=line.split('  ',1);assert sha((out/n).read_bytes())==h
print(json.dumps(dict(completeXcresults=bundles,nativePassed=dict(ios=257,macos=232),toolTests=211,sourceFiles=442,binaryFiles=307,rawMediaFiles=len(read(r/'media-raw-identity.json')),strictPasses=0,totalMediaRuns=3,reassessedPasses=0,budgetScenarioEstablished=True,budgetExhaustedFinalWidth=320,historicalGroups=50,historicalHashEntries=10531,ledgerStatusesUnchanged=102,productionSourceUnchanged=True,sourceMatches=True,releaseReady=False),indent=2))
