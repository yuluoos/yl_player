from pathlib import Path
import json,hashlib,sys
r=Path('/private/tmp/yl-half-close-fix');old=Path('/private/tmp/yl-cancel-byte-boundaries')
for name in ['run-media.py','analyze.py','bytes.py','readiness.py','bind-native.py','archive.py']:
 s=(old/name).read_text().replace(str(old),str(r))
 if name=='run-media.py':s=s.replace('ios-final-result.json','ios-fixed-result.json')
 if name=='bind-native.py':s=s.replace("platform+'-final'","platform+'-fixed'")
 if name=='archive.py':
  s=s.replace('2026-10-29-ios-cancel-byte-boundaries','2026-10-29-ios-half-close-fix');a=s.index("(out/'README.md').write_text(");b=s.index('\nfiles=sorted',a);s=s[:a]+"(out/'README.md').write_text('半关闭生产修复及有界连接回收：保留红测、绿测、初轮fixture失败、最终选定矩阵、两轮长素材和全部原始附件。详见 ../../2026-10-29-ios-half-close-fix.md。\\n')"+s[b:]
 (r/name).write_text(s)
(r/'profiles.json').write_bytes((old/'profiles.json').read_bytes())
keys=json.loads((old/'source-identity.json').read_text());(r/'source-identity.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in keys},indent=2)+'\n')
p=Path('/private/tmp/yl-production-exercise/ios-build/Build/Products');(r/'binary-identity.json').write_text(json.dumps({str(v.relative_to(p)):hashlib.sha256(v.read_bytes()).hexdigest() for v in p.rglob('*') if v.is_file() and ('.app/' in str(v) or v.suffix=='.xctestrun')},indent=2)+'\n')
sys.path.insert(0,'tool/release_readiness');from check import source_snapshot
(r/'production-source.json').write_text(json.dumps(source_snapshot(Path.cwd()),indent=2)+'\n')
