from pathlib import Path
import json,shutil,gzip,hashlib,subprocess,tarfile
root=Path.cwd(); src=Path('/private/tmp/yl-continuity-runs'); dest=root/'docs/superpowers/reports/evidence/2026-10-27-abr-frame-retention';dest.mkdir(parents=True,exist_ok=True);manifest=[]
def copy(f,out):
 data=f.read_bytes();out.parent.mkdir(parents=True,exist_ok=True)
 if f.suffix in ['.log','.patch'] or len(data)>500000:out=out.with_name(out.name+'.gz');out.write_bytes(gzip.compress(data,mtime=0))
 else:out.write_bytes(data)
 manifest.append(dict(source=str(f),archive=str(out.relative_to(dest)),rawSha256=hashlib.sha256(data).hexdigest(),rawBytes=len(data)))
for directory,label in [(src,'runs'),(Path('/private/tmp/yl-continuity-final-checks'),'final-checks'),(Path('/private/tmp/yl-continuity-physical-controls'),'physical-controls'),(Path('/private/tmp/yl-continuity-physical-runs'),'physical-initial'),(Path('/private/tmp/yl-continuity-physical-retry'),'physical-retry'),(Path('/private/tmp/yl-continuity-checks'),'checks'),(Path('/private/tmp/yl-continuity-device'),'device')]:
 if not directory.exists():continue
 for f in sorted(directory.rglob('*')):
  if not f.is_file() or any(p.endswith('.xcresult') for p in f.parts) or f.suffix in ['.m4s','.mp4']:continue
  copy(f,dest/label/f.relative_to(directory))
exclude={'yl-continuity-devices.json','yl-continuity-device-discovery.log','yl-continuity-device-details.json','yl-continuity-device-details.log','yl-continuity-signing-identities.log','yl-continuity-local-signing-summary.json'}
for f in Path('/private/tmp').glob('yl-continuity-*'):
 if f.is_file() and f.name not in exclude and not any(word in f.name for word in ['-private','-battery-','-device-process-schema']):copy(f,dest/('scripts' if f.suffix=='.py' else 'checks')/f.name)
bundles=list(Path('/private/tmp/yl-continuity-physical-controls').glob('*.xcresult'))+list(Path('/private/tmp/yl-continuity-physical-runs').glob('*.xcresult'))+list(Path('/private/tmp/yl-continuity-physical-retry').glob('*.xcresult'))+list(src.glob('*.xcresult'))+list(Path('/private/tmp').glob('yl-continuity-*.xcresult'))+list(Path('/private/tmp/yl-continuity-device').glob('*.xcresult'))
for bundle in bundles:
 label=(bundle.parent.name+'-') if 'physical' in bundle.parent.name else '';out=dest/'xcresult'/(label+bundle.name+'.tar.gz');out.parent.mkdir(parents=True,exist_ok=True)
 summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],capture_output=True,text=True);assert summary.returncode==0,summary.stderr
 (out.parent/(label+bundle.name+'-summary.json')).write_text(summary.stdout)
 with tarfile.open(out,'w:gz') as tar:tar.add(bundle,arcname=bundle.name)
for name in sorted(set(subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()+subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','tool/playback_network'],text=True).splitlines())):
 if name.startswith(('tool/playback_network/','tool/consumer_fixtures/','packages/')):copy(root/name,dest/'source-final'/name)
(dest/'archive-provenance.json').write_text(json.dumps(dict(omitted='Duplicate generated media .m4s/.mp4 bound to unchanged repository media inventories; unrelated device/certificate details excluded in favor of scoped summaries. Full XCTest results included.',files=manifest),indent=2)+'\n')
print('archived',len(manifest),'files',len(bundles),'result bundles',flush=True)
