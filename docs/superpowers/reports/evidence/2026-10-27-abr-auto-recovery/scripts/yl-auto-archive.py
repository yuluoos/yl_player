from pathlib import Path
import json,shutil,gzip,hashlib,subprocess,tarfile
root=Path.cwd(); src=Path('/private/tmp/yl-auto-20261027'); dest=root/'docs/superpowers/reports/evidence/2026-10-27-abr-auto-recovery';dest.mkdir(parents=True,exist_ok=True);manifest=[]
def copy(f,out):
 data=f.read_bytes();out.parent.mkdir(parents=True,exist_ok=True)
 if f.suffix in ['.log','.patch'] or len(data)>500000: out=out.with_name(out.name+'.gz');out.write_bytes(gzip.compress(data,mtime=0))
 else:out.write_bytes(data)
 manifest.append({'source':str(f),'archive':str(out.relative_to(dest)),'rawSha256':hashlib.sha256(data).hexdigest(),'rawBytes':len(data)})
for f in sorted(src.rglob('*')):
 if not f.is_file() or any(p.endswith('.xcresult') for p in f.parts) or f.suffix in ['.m4s','.mp4']:continue
 copy(f,dest/'runs'/f.relative_to(src))
for bundle in list(src.glob('*.xcresult'))+[Path('/private/tmp/yl-auto-contracts.xcresult'),Path('/private/tmp/yl-auto-review-contract.xcresult')]:
 out=dest/'xcresult'/(bundle.name+'.tar.gz');out.parent.mkdir(parents=True,exist_ok=True)
 summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],capture_output=True,text=True); assert summary.returncode==0
 (out.parent/(bundle.name+'-summary.json')).write_text(summary.stdout)
 with tarfile.open(out,'w:gz') as tar:tar.add(bundle,arcname=bundle.name)
for f in Path('/private/tmp').glob('yl-auto-*'):
 if f.is_file():copy(f,dest/('scripts' if f.suffix=='.py' else 'checks')/f.name)
for name in subprocess.check_output(['git','diff','--name-only'],text=True).splitlines():
 if name.startswith(('tool/playback_network/','tool/consumer_fixtures/','packages/')):copy(root/name,dest/'source-final'/name)
(dest/'archive-provenance.json').write_text(json.dumps({'omitted':'Generated .m4s/.mp4 media only, bound by inventories to unchanged repository media. Full original xcresult bundles separately archived.','files':manifest},indent=2)+'\n')
print('Archived originals',len(manifest),'at',dest)
