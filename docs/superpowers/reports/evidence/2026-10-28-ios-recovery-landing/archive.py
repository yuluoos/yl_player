from pathlib import Path
import os,json,hashlib,gzip,tarfile,subprocess
raw=Path('/private/tmp/yl-recovery-landing');out=Path('docs/superpowers/reports/evidence/2026-10-28-ios-recovery-landing');out.mkdir(parents=True,exist_ok=True)
sha=lambda data:hashlib.sha256(data).hexdigest()
old=json.loads((out/'raw-provenance.json').read_text()) if (out/'raw-provenance.json').exists() else []
records=[]
for bundle in sorted(raw.glob('*.xcresult')):
 files={str(p.relative_to(bundle)):sha(p.read_bytes()) for p in bundle.rglob('*') if p.is_file()}
 saved=next((r for r in old if r['source']==bundle.name and r.get('bundleFiles')==files),None)
 if saved:records.append(saved);continue
 temp=raw/(bundle.name+'.tar.gz')
 with tarfile.open(temp,'w:gz') as tar:tar.add(bundle,arcname=bundle.name)
 digest=hashlib.sha256();parts=[]
 with temp.open('rb') as f:
  i=0
  while data:=f.read(15*1024*1024):
   dest=out/(bundle.name+'.tar.gz.part'+str(i).zfill(3));dest.write_bytes(data);digest.update(data)
   parts.append(dict(path=dest.name,sha256=sha(data)));i+=1
 records.append(dict(source=bundle.name,archiveParts=parts,archiveSha256=digest.hexdigest(),bundleFiles=files))
 temp.unlink()
for folder,dirs,names in os.walk(raw):
 dirs[:]=[n for n in dirs if n not in ['ios-build','macos-build','__pycache__'] and not n.endswith('.xcresult')]
 for name in sorted(names):
  p=Path(folder)/name
  if p.suffix=='.pyc' or p.name.endswith('.tar.gz'):continue
  rel=p.relative_to(raw);data=p.read_bytes();dest=out/rel
  compressed=p.suffix in ['.log','.swift','.patch'] or p.name in ['more-tests.txt','relay-tests.txt'] or len(data)>128*1024
  if compressed:
   if dest.exists():dest.unlink()
   dest=Path(str(dest)+'.gz')
  dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(gzip.compress(data,mtime=0) if compressed else data)
  records.append(dict(source=str(rel),sourceSha256=sha(data),archive=str(dest.relative_to(out)),archiveSha256=sha(dest.read_bytes()),compressed=compressed))
(out/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'README.md').write_text('本轮恢复定位失败、提交拒绝与超时隔离合约，以及断连窗口漏检修复证据。原生原始红灯、原网络失败、定向工具红灯、最终完整xcresult和源码绑定均保留。原生用例使用可控回调，不代替新制品长素材或物理音画验收。raw-provenance.json记录原始字节/完整结果包文件映射，SHA256SUMS覆盖归档。\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS')
assert all(p.stat().st_size<=16*1024*1024 for p in files)
(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files))
print('archive',len(records),'records',len(files),'files')
