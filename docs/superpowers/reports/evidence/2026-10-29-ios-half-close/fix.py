from pathlib import Path
import json,hashlib
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();a=s.index('  func testHalfClosedClient');b=s.index('  func testUnoccupiedProxyCancellation',a);t=s[a:b].replace('    for proxied in [false, true] {','''    for proxied in [false, true] {
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      if proxied {
        // Hold only the response, after admission; isolate EOF from success.
        server.handler = { _ in
          XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
          return (200, [:], Data([1, 2, 3, 4]))
        }
      }''');s=s[:a]+t+s[b:];p.write_text(s)
for v in ('ios','macos'):Path(f'packages/yl_player/example/{v}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
r=Path('/private/tmp/yl-half-close');(r/'source-before-gate.json').write_bytes((r/'source-identity.json').read_bytes());keys=json.loads((r/'source-identity.json').read_text());(r/'source-identity.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in keys},indent=2)+'\n')
p=r/'run.py';s=p.read_text().replace("source='native-green'", "source='native-green'")
s=s.replace("else n)","else {'macos-confirm':'macos-final','ios-confirm':'ios-final'}.get(n,n))")
s=s.replace("if n.startswith('native-probe'):","if n.startswith('native-probe') or n.endswith('-confirm') and not n.startswith('ios-build'):")
p.write_text(s)
