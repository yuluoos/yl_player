import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).parent
out = root/sys.argv[1]
out.mkdir()
app = root/'source/packages/yl_player/example/build/macos/Build/Products/Release/yl_player_example.app'
images = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in app.rglob('*') if p.is_file() and not p.is_symlink()}
inputs = {str(p.relative_to(root/'source')): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in (root/'source/packages/yl_player_apple/darwin/yl_player_apple/Sources').rglob('*.swift')}
(out/'plan.json').write_text(json.dumps({'purpose': 'first-failure-diagnosis', 'product': images,
    'nativeSources': inputs, 'maximumSeconds': 1350, 'productionQualification': False}, indent=2)+'\n')
with (out/'raw.log').open('x') as log:
    p = subprocess.Popen([str(app/'Contents/MacOS/yl_player_example')], stdout=log, stderr=log,
        env={**os.environ, 'NSUnbufferedIO':'YES', 'YL_AV1_VISIBLE_QUALIFICATION':'1'})
    (out/'pid').write_text(str(p.pid))
    awake = subprocess.Popen(['/usr/bin/caffeinate', '-d', '-i', '-u', '-w', str(p.pid)])
    try:
        code = p.wait(timeout=1350)
    except subprocess.TimeoutExpired:
        p.terminate()
        try: code = p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); code = p.wait()
    finally:
        awake.wait(timeout=5)
(out/'exit.json').write_text(json.dumps({'exit': code, 'pid': p.pid})+'\n')
print(out, 'exit', code)
