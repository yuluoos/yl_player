from pathlib import Path
import json,sys,collections,hashlib
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');import main_example_tests as m
r=Path('/private/tmp/yl-request-timing');scope={}
for name,platform in [('macos','macos'),('device','ios')]:
 d=json.loads((r/f'final-{name}-tests.json').read_text());nodes=list(m.case_nodes(d['testNodes']));ids=[x['nodeIdentifier'] for x in nodes];assert len(ids)==len(set(ids));classes={x.split('/')[0] for x in ids};expected={x for x in m.expected_identities(Path('tool/consumer_fixtures/apple_flutter'),platform) if x.split('/')[0] in classes};assert set(ids)==expected,(name,expected-set(ids),set(ids)-expected)
 assert all(x['result']=='Passed' for x in nodes)
 scope[name]=dict(passed=len(ids),failed=0,skipped=0,classes=dict(sorted(collections.Counter(x.split('/')[0] for x in ids).items())))
identity=json.loads((r/'source-identity.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in identity.items())
(r/'final-native-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),scope=scope),indent=2)+'\n');print({k:v['passed'] for k,v in scope.items()})
