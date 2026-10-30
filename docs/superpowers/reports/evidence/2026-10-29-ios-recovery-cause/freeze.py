from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-recovery-cause');old=Path('/private/tmp/yl-budget-metrics');previous=json.loads((old/'source-identity.json').read_text());paths=list(previous)
for name in ['connection_lifecycle.py','test_connection_lifecycle.py']:
 p=str(Path('tool/playback_network',name).resolve())
 if p not in paths:paths.append(p)
identity={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sorted(paths)}
for n in ['source-identity.json','capture-source-identity.json']:(r/n).write_text(json.dumps(identity,indent=2)+'\n')
products=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');binary={str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')};assert binary==json.loads((old/'binary-identity.json').read_text());(r/'binary-identity.json').write_text(json.dumps(binary,indent=2)+'\n')
unchanged={p:h for p,h in previous.items() if p.startswith(('packages/','tool/consumer_fixtures/'))};assert len(unchanged)>300;assert all(identity[p]==h for p,h in unchanged.items())
(r/'native-reuse.json').write_text(json.dumps(dict(base='9efd8319',nativeInputsUnchanged=unchanged,binaryFiles=len(binary),priorEvidence='docs/superpowers/reports/evidence/2026-10-29-ios-budget-metrics',ios=249,macos=224,newNativeMatrixRun=False),indent=2)+'\n')
print('source',len(identity),'binary',len(binary),'unchanged native inputs',len(unchanged))
