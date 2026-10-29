from pathlib import Path
import json,hashlib,gzip,tarfile,io
raw=Path('/private/tmp/yl-production-recovery');out=Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-recovery');out.mkdir(parents=True,exist_ok=True)
sha=lambda b:hashlib.sha256(b).hexdigest();records=[]
# Preserve all test result bundles, including red tests and failed media captures.
bundles=sorted(raw.rglob('*.xcresult'))
for bundle in bundles:
 rel=bundle.relative_to(raw);path=out/(str(rel)+'.tar.gz');path.parent.mkdir(parents=True,exist_ok=True)
 with tarfile.open(path,'w:gz') as t:t.add(bundle,arcname=bundle.name)
 data=path.read_bytes();record=dict(source=str(rel),archive=str(path.relative_to(out)),archiveSha256=sha(data),bundleFiles=sum(p.is_file() for p in bundle.rglob('*')))
 if len(data)>15*1024*1024:
  parts=[]
  for i,start in enumerate(range(0,len(data),15*1024*1024)):
   part=Path(str(path)+f'.part{i:03d}');part.write_bytes(data[start:start+15*1024*1024]);parts.append(dict(path=str(part.relative_to(out)),sha256=sha(part.read_bytes()),bytes=part.stat().st_size))
  manifest=Path(str(path)+'.parts.json');manifest.write_text(json.dumps(dict(sha256=sha(data),bytes=len(data),parts=parts),indent=2)+'\n');path.unlink();record['archive']=str(manifest.relative_to(out));record['archiveParts']=parts
 records.append(record)
for path in sorted(raw.rglob('*')):
 if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc' or any(p.suffix=='.xcresult' for p in path.parents):continue
 rel=path.relative_to(raw)
 if rel.name in {'device-processes.json','device-processes.log','usb-devices.json','xcdevices.json','xcdevices-reconnected.json','device-details.json','device-details.log','flutter-devices.json'}:continue
 if rel.name=='apple-local-networking.md':continue # Official page linked and fingerprinted separately.
 if 'fixture' in rel.parts and path.name not in ['manifest.mpd','SHA256SUMS']:continue
 # Large generated binary artifacts are contained in complete xcresult bundles; no app/provisioning copy.
 data=path.read_bytes();dest=out/rel;compressed=(path.suffix in ['.log','.jsonl','.swift'] or path.name=='StandardOutputAndStandardError.txt') or len(data)>128*1024
 if compressed:dest=Path(str(dest)+'.gz')
 dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(gzip.compress(data,mtime=0) if compressed else data)
 records.append(dict(source=str(rel),sourceSha256=sha(data),archive=str(dest.relative_to(out)),archiveSha256=sha(dest.read_bytes())))
(out/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'README.md').write_text('本轮生产 iOS 同源恢复接入证据：保留 listener 地址失败、耳机路由移除暂停失败、红灯测试和早期制品；最终同制品三轮原配置/自动替换/公开暂停恢复采集，原生 iPhone222与macOS197重新执行，网络127、消费者45通过1跳过。实际发布帧与替换边界不能代替物理音画连续性验收。完整xcresult、两阶段源码绑定、raw-provenance.json与SHA256SUMS提供字节校验。历史22组5359文件保持未变。\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS')
(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files))
print(dict(completeBundles=len(bundles),rawEntries=len(records),manifestEntries=len(files)))
