from pathlib import Path
import json,collections
r=Path('/private/tmp/yl-budget-metrics');out={}
for platform,count in [('ios',249),('macos',224)]:
 tree=json.loads((r/(platform+'-final-tests.json')).read_text());cases=[]
 def visit(nodes):
  for n in nodes:
   if n.get('nodeType')=='Test Case':cases.append(n)
   visit(n.get('children',[]))
 visit(tree['testNodes']);ids=[n['nodeIdentifier'] for n in cases]
 assert len(ids)==len(set(ids))==count and all(n['result']=='Passed' for n in cases)
 for n in cases:
  cls,method=n['nodeIdentifier'].split('/');method=method.removesuffix('()');matches=list(Path('packages/yl_player/example',platform,'RunnerTests').rglob('*.swift'))
  assert any('class '+cls in p.read_text() and 'func '+method+'(' in p.read_text() for p in matches),(cls,method)
 assert any('testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose' in i for i in ids)
 out[platform]=dict(passed=count,uniqueIdentities=sorted(ids),classes=dict(collections.Counter(i.split('/')[0] for i in ids)),failed=0,skipped=0)
(r/'native-binding.json').write_text(json.dumps(out,indent=2)+'\n');print({p:d['passed'] for p,d in out.items()})
