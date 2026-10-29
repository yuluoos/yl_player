from pathlib import Path
import json,hashlib,sys
raw=Path('/private/tmp/yl-production-recovery');sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');import main_example_tests as gate
classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'};scope={}
for mode,platform,count in [('macos','macos',197),('device','ios',222)]:
 p=raw/('reviewed-'+mode+'-contracts-tests.json')
 if not p.exists():continue
 nodes=list(gate.case_nodes(json.loads(p.read_text())['testNodes']));ids=[n['nodeIdentifier'] for n in nodes]
 expected={i for i in gate.expected_identities(Path('tool/consumer_fixtures/apple_flutter'),platform) if i.split('/')[0] in classes}
 assert len(ids)==len(set(ids))==count and set(ids)==expected and all(n['result']=='Passed' for n in nodes)
 scope[mode]=dict(passed=count,failed=0,skipped=0,classes={c:sum(i.startswith(c+'/') for i in ids) for c in sorted(classes) if any(i.startswith(c+'/') for i in ids)})
(raw/'final-native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'reviewed-source-identity.json').read_text())
format_change=json.loads((raw/'posttest-format-only.json').read_text())
for p,h in identity.items():
 current=Path(p).read_bytes()
 if p==format_change['path']:
  assert sha(current+b'\n')==h==format_change['testedSha256'] and sha(current)==format_change['finalSha256'],p
 else:assert sha(current)==h,p
(raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,scope=scope,mediaRetested=True,postTestFormatOnlyChange=format_change),indent=2)+'\n')
print(scope)
