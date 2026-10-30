from pathlib import Path
import hashlib,json
r=Path('/private/tmp/yl-cancel-byte-boundaries');p=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products')
assert json.loads((r/'ios-build-final-result.json').read_text())['exitCode']==0
binary={str(v.relative_to(p)):hashlib.sha256(v.read_bytes()).hexdigest() for v in p.rglob('*') if v.is_file() and ('.app/' in str(v) or v.suffix=='.xctestrun')}
(r/'binary-identity.json').write_text(json.dumps(binary,indent=2)+'\n');print(len(binary))
