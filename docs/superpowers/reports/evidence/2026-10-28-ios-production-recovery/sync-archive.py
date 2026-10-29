from pathlib import Path
import json,hashlib,gzip
raw=Path('/private/tmp/yl-production-recovery');out=Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-recovery');sha=lambda b:hashlib.sha256(b).hexdigest()
records=[r for r in json.loads((out/'raw-provenance.json').read_text()) if 'bundleFiles' in r]
for path in sorted(raw.rglob('*')):
 if not path.is_file() or '__pycache__' in path.parts or path.suffix=='.pyc' or any(p.suffix=='.xcresult' for p in path.parents):continue
 rel=path.relative_to(raw)
 if rel.name in {'device-processes.json','device-processes.log','usb-devices.json','xcdevices.json','xcdevices-reconnected.json','device-details.json','device-details.log','flutter-devices.json','apple-local-networking.md'}:continue
 if 'fixture' in rel.parts and path.name not in ['manifest.mpd','SHA256SUMS']:continue
 data=path.read_bytes();dest=out/rel;compressed=path.suffix in ['.log','.jsonl','.swift'] or path.name=='StandardOutputAndStandardError.txt' or len(data)>128*1024
 if compressed:dest=Path(str(dest)+'.gz')
 dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(gzip.compress(data,mtime=0) if compressed else data)
 records.append(dict(source=str(rel),sourceSha256=sha(data),archive=str(dest.relative_to(out)),archiveSha256=sha(dest.read_bytes())))
(out/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
files=sorted(p for p in out.rglob('*') if p.is_file() and p.name!='SHA256SUMS');(out/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(out))+'\n' for p in files));print('synced',len(records),'raw records;',len(files),'manifest files')
