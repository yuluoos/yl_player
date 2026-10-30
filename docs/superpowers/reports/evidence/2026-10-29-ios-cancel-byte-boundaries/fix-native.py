from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();a=s.index('  func testUnoccupiedProxyCancellation');b=s.index('  func testProxyRequestTimingRecordsRealCancellation',a);block=s[a:b]
for k in ('outcome','bodyBytes','sentBodyBytes'):block=block.replace(f'row["{k}"] as? Int',f'row["{k}"] as? Double')
s=s[:a]+block+s[b:];p.write_text(s)
for v in ('ios','macos'):Path(f'packages/yl_player/example/{v}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
p=Path('/private/tmp/yl-cancel-byte-boundaries/run.py');s=p.read_text().replace("source='native-green' if n=='native-probe' else n","source='native-green' if n.startswith('native-probe') else n.removesuffix('-repeat')").replace("if n=='native-probe':","if n.startswith('native-probe'):").replace("if n!='ios-build':","if not n.startswith('ios-build'):");p.write_text(s)
