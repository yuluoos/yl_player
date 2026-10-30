import sys,json
from pathlib import Path
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter')
import main_example_tests as m
r=Path('/private/tmp/yl-reset-retry-control')
for platform in ('ios','macos'):
 name=platform+'-final'
 cmd=json.loads((r/(name+'-command.json')).read_text());classes={s.split('/')[-1] for s in cmd if s.startswith('-only-testing:')}
 expected=m.expected_identities(Path('tool/consumer_fixtures/apple_flutter'),platform)
 selected={i for i in expected if i.split('/')[0] in classes}
 m.verify_result_bundle(Path.cwd(),r/(name+'.xcresult'),platform,r/(platform+'-binding'),selected=selected)
