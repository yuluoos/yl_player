import hashlib,json,subprocess,sys
from pathlib import Path
paths=subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()+subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True).splitlines()
paths=sorted(p for p in paths if p.startswith(('packages/','tool/media_matrix/')) and Path(p).is_file())
Path(sys.argv[1]).write_text(json.dumps(dict(base=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),sources={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths}),indent=2)+'\n')
