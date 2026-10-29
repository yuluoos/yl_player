from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-cancel-byte-boundaries');old=Path('/private/tmp/yl-transaction-bytes')
for name in ('run-media.py','analyze.py','bytes.py','diagnose.py','resource-relations.py','transition-context.py','video-transition-pairs.py','bind-native.py','readiness.py'):
 (r/name).write_text((old/name).read_text().replace('/private/tmp/yl-transaction-bytes',str(r)))
(r/'profiles.json').write_bytes((old/'profiles.json').read_bytes())
for key in ['source-identity.json','capture-source-identity.json']:
 original=json.loads((old/'source-identity.json').read_text());out={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in original};(r/key).write_text(json.dumps(out,indent=2)+'\n')
(r/'production-source.json').write_bytes((old/'production-source.json').read_bytes())
p=r/'history.py';s=(old/'history.py').read_text().replace("Path('/private/tmp/yl-transaction-bytes')",f"Path('{r}')").replace("Path('/private/tmp/yl-failure-observations/prior-evidence.json')","Path('/private/tmp/yl-transaction-bytes/prior-evidence.json')").replace("group='2026-10-29-ios-failure-observations'","group='2026-10-29-ios-transaction-bytes'").replace('d5f437f4','524f31a0');p.write_text(s)
replay=r/'legacy-replay';replay.mkdir(exist_ok=True);(replay/'replay.py').write_text((old/'legacy-replay/replay.py').read_text().replace('/private/tmp/yl-transaction-bytes/legacy-replay',str(replay)))
