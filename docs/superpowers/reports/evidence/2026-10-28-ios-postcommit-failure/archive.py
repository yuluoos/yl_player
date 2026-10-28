from pathlib import Path
import json,hashlib,gzip,tarfile,io
raw=Path('/private/tmp/yl-postcommit-failure');out=Path('docs/superpowers/reports/evidence/2026-10-28-ios-postcommit-failure');out.mkdir(parents=True,exist_ok=True)
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
 data=path.read_bytes();dest=out/rel;compressed=path.suffix in ['.log','.jsonl','.swift'] or len(data)>128*1024
 if compressed:dest=Path(str(dest)+'.gz')
 dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(gzip.compress(data,mtime=0) if compressed else data)
 records.append(dict(source=str(rel),sourceSha256=sha(data),archive=str(dest.relative_to(out)),archiveSha256=sha(dest.read_bytes())))
(out/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'README.md').write_text('''# 验收原始证据

完整保留全部xcresult（含红灯和媒体失败）。较大tar.gz按15MiB顺序分片，按parts.json中的顺序连接、核对组合SHA256后再解压。普通.gz还原为raw-provenance.json记录的原始字节。SHA256SUMS覆盖所有归档文件；原测试制品绑定见source-identity与各receipt。

本轮使用已存在的本地素材和受控回环网络合约，没有新增120秒ABR媒体采集。新增原生测试字段编译错误、Dart事件时序失败及无线启动失败均保留；不把阶段策略/帧校验通过等同EOF、完整ABR或物理音画连续性验收。
''')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS')
(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files))
print(dict(completeBundles=len(bundles),rawEntries=len(records),manifestEntries=len(files)))
