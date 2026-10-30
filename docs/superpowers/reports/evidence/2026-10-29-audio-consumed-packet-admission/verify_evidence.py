from pathlib import Path
import json,sys,subprocess,hashlib
root=Path.cwd();out=Path('/private/tmp/yl-audio-admission');sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'));import main_example_tests as m
bundle=out/'core-affected.xcresult'
for kind in ['summary','tests']:
 result=subprocess.check_output(['xcrun','xcresulttool','get','test-results',kind,'--path',str(bundle)])
 (out/f'core-affected-{kind}.json').write_bytes(result)
classes={'YlManagedSoftwareAudioTests','YlContainerOutputTests','YlOpenedMediaTests','YlMacosAudioTests'}
expected=m.expected_identities(root/'tool/consumer_fixtures/apple_flutter','macos')
selected={x for x in expected if x.split('/')[0] in classes}
tree=json.loads((out/'core-affected-tests.json').read_text());summary=json.loads((out/'core-affected-summary.json').read_text())
receipt=m.verify_runtime(tree,summary,selected,'macos');(out/'core-affected-identities.json').write_text(json.dumps(receipt,indent=2)+'\n')
old={x['nodeIdentifier']:x['result'] for x in m.case_nodes(json.loads((out/'full-macos-tests.json').read_text())['testNodes'])}
new={x['nodeIdentifier']:x['result'] for x in m.case_nodes(tree['testNodes'])}
assert set(old)==set(json.loads((out/'full-macos-expected.json').read_text()))
reused={k:v for k,v in old.items() if k not in new};assert set(reused)|set(new)==expected
assert all(v=='Passed' for v in reused.values());assert all(v=='Passed' for v in new.values())
for p,sha in json.loads((out/'core-candidate-source.json').read_text()).items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==sha,p
combined={'scope':'Per-case union, NOT one complete final-candidate run','expectedRuntimeIdentities':len(expected),'finalCandidateExecuted':len(new),'unchangedScopeReused':len(reused),'totalCovered':len(expected),'failed':0,'skipped':0,'originalFullRun':{'passed':915,'failed':1,'skipped':0},'reuseBasis':'Final changes are DTS core admission estimates and rejection of a single estimate exceeding the effective total duration limit. DTS output and primary renderer classes rerun; other first-run cases retain their original receipts. Shared managed characterization cases use unchanged non-DTS estimators within their effective total time windows (20/21ms test buffers; 1x/2x playback). No bridge, build, dependency, public protocol, fixture payload or non-audio production changes.','reused':sorted(reused),'finalCandidate':sorted(new)}
(out/'combined-coverage.json').write_text(json.dumps(combined,indent=2)+'\n');print({k:v for k,v in combined.items() if k not in ['reused','finalCandidate','reuseBasis']})
