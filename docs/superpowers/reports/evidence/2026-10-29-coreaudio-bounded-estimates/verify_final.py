from pathlib import Path
import sys,json,hashlib,subprocess
root=Path.cwd();out=Path('/private/tmp/yl-coreaudio-bounds');sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'));import main_example_tests as m
classes={'YlManagedSoftwareAudioTests','YlContainerOutputTests','YlOpenedMediaTests','YlMacosAudioTests','YlManagedFallbackCharacterizationTests'}
expected={x for x in m.expected_identities(root/'tool/consumer_fixtures/apple_flutter','macos') if x.split('/')[0] in classes}
for kind in ['summary','tests']:
 (out/f'consolidated-{kind}.json').write_bytes(subprocess.check_output(['xcrun','xcresulttool','get','test-results',kind,'--path',str(out/'consolidated.xcresult')]))
s=json.loads((out/'consolidated-summary.json').read_text());tree=json.loads((out/'consolidated-tests.json').read_text());r=m.verify_runtime(tree,s,expected,'macos');r.update(coverage='Complete affected five-class matrix; not the complete canonical suite',candidate='candidate-source.json',resultBundle=str(out/'consolidated.xcresult'));(out/'consolidated-identities.json').write_text(json.dumps(r,indent=2)+'\n')
for f,sha in json.loads((out/'candidate-source.json').read_text()).items():assert hashlib.sha256((root/f).read_bytes()).hexdigest()==sha,f
print('Verified affected identities',len(expected),'passed',s['passedTests'],'failed',s['failedTests'],'skipped',s['skippedTests'])
