"""Package byte-identical owned DASH media for sandboxed native test bundles."""
import base64
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media/dash_timeline'

def payload():
    return json.dumps({str(p.relative_to(MEDIA)): base64.b64encode(p.read_bytes()).decode()
                       for p in sorted(MEDIA.rglob('*')) if p.suffix in ('.mpd', '.m4s')}, sort_keys=True) + '\n'

if __name__ == '__main__':
    contents = payload()
    for folder in ('tool/consumer_fixtures/apple_flutter/Resources',
                   'packages/yl_player/example/ios/RunnerTests',
                   'packages/yl_player/example/macos/RunnerTests'):
        (ROOT / folder / 'p01-program-fixtures.json').write_text(contents)
