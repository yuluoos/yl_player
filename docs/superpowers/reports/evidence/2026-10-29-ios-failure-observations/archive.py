from pathlib import Path
import os,json,hashlib,gzip,tarfile,subprocess
raw=Path('/private/tmp/yl-failure-observations');out=Path('docs/superpowers/reports/evidence/2026-10-29-ios-failure-observations');out.mkdir(parents=True,exist_ok=True)
sha=lambda data:hashlib.sha256(data).hexdigest()
old=json.loads((out/'raw-provenance.json').read_text()) if (out/'raw-provenance.json').exists() else []
records=[]
for bundle in sorted(raw.rglob('*.xcresult')):
 relative=str(bundle.relative_to(raw))
 files={str(p.relative_to(bundle)):sha(p.read_bytes()) for p in bundle.rglob('*') if p.is_file()}
 saved=next((r for r in old if r['source']==relative and r.get('bundleFiles')==files),None)
 if saved:records.append(saved);continue
 temp=raw/(bundle.name+'.tar.gz')
 with tarfile.open(temp,'w:gz') as tar:tar.add(bundle,arcname=relative)
 digest=hashlib.sha256();parts=[]
 with temp.open('rb') as f:
  i=0
  while data:=f.read(15*1024*1024):
   dest=out/(relative+'.tar.gz.part'+str(i).zfill(3));dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data);digest.update(data)
   parts.append(dict(path=str(dest.relative_to(out)),sha256=sha(data)));i+=1
 records.append(dict(source=relative,archiveParts=parts,archiveSha256=digest.hexdigest(),bundleFiles=files))
 temp.unlink()
for folder,dirs,names in os.walk(raw):
 dirs[:]=[n for n in dirs if n not in ['ios-build','macos-build','__pycache__'] and not n.endswith('.xcresult')]
 for name in sorted(names):
  p=Path(folder)/name
  if p.suffix=='.pyc' or p.name.endswith('.tar.gz'):continue
  rel=p.relative_to(raw)
  if 'fixture' in rel.parts and p.name not in ['manifest.mpd','SHA256SUMS']:continue
  data=p.read_bytes();dest=out/rel
  compressed=p.suffix in ['.log','.swift','.patch','.txt','.jsonl'] or p.name in ['more-tests.txt','relay-tests.txt'] or len(data)>128*1024
  if compressed:
   if dest.exists():dest.unlink()
   dest=Path(str(dest)+'.gz')
  dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(gzip.compress(data,mtime=0) if compressed else data)
  records.append(dict(source=str(rel),sourceSha256=sha(data),archive=str(dest.relative_to(out)),archiveSha256=sha(dest.read_bytes()),compressed=compressed))
(out/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'README.md').write_text('失败回执诊断修复证据：旧四轮离线重算及两轮新真机采集分开记录，包含2个新增完整xcresult。保留红测、原始失败和消费者错误发现日志。原生完整矩阵复用66d12aa3，未重新构建或重跑；不授予整体ABR或物理音画验收。详情见 ../../2026-10-29-ios-failure-observations.md。\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS')
assert all(p.stat().st_size<=16*1024*1024 for p in files)
(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files))
print('archive',len(records),'records',len(files),'files')
