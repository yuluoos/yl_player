from pathlib import Path
import subprocess,json,sys,shutil,hashlib
raw=Path('/private/tmp/yl-public-transport')
mode=sys.argv[1]
if mode=='snapshot':
 for p in ['source-identity.json']:
  shutil.copyfile(raw/p,raw/('pre-review-'+p))
 identity=json.loads((raw/'source-identity.json').read_text())
 identity['tool/playback_network/test_abr_policy.py']=''
 for p in identity:
  src=Path(p);dest=raw/'review-source'/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(src.read_bytes());identity[p]=hashlib.sha256(src.read_bytes()).hexdigest()
 (raw/'review-source-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
else:
 src=(raw/('build.py' if mode=='build' else 'run-candidate.py')).read_text()
 if mode=='build':src=src.replace("'build-command.json'","'review-build-command.json'").replace("'build.log'","'review-build.log'").replace("'build-result.json'","'review-build-result.json'")
 else:src=src.replace("'candidate-'","'review-'")
 sys.argv=['review',mode]
 exec(compile(src,'review','exec'))
