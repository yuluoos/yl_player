from pathlib import Path
import json,hashlib,gzip,tarfile,io
raw=Path('/private/tmp/yl-production-races');out=Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-races');out.mkdir(parents=True,exist_ok=True)
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
(out/'README.md').write_text('本轮 iOS 生产恢复候选提交前公开暂停/跳转/Load竞争、Load返回预算修复及三轮重复高档恢复证据。完整xcresult、原始预算失败、早期收据与严格重评、全部红灯/消费者失败均保留。实际帧PTS与替换边界不等于物理音画连续性验收。raw-provenance.json、SHA256SUMS与final-verification.json提供逐字节核对，历史23组证据保持不变。\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS')
(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files))
print(dict(completeBundles=len(bundles),rawEntries=len(records),manifestEntries=len(files)))
