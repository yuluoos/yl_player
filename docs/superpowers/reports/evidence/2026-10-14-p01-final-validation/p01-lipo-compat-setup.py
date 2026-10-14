"""Recreate the opt-in adapter used by the archived owned-consumer drivers."""
from pathlib import Path
import os,sys
root=Path(os.environ['YL_REPO_ROOT']).resolve()
source=(root/'tool/consumer_fixtures/apple_flutter/lipo_verify_compat.py').read_text().splitlines()
folder=Path('/private/tmp/p01-lipo-compat');folder.mkdir(exist_ok=True)
script='#!'+sys.executable+'\n'+'\n'.join(source[1:])+'\n'
path=folder/'lipo'
if path.exists() and path.read_text()!=script:
 raise SystemExit('Refusing to replace a different existing adapter')
path.write_text(script);path.chmod(0o755)
