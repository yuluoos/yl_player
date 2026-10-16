"""Preserve original outcomes; no binary builds or cached bytecode in Git."""
import gzip,json,hashlib,shutil
from pathlib import Path
scratch=Path('/private/tmp/yl-p03-full-public-20261016')
out=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player/docs/superpowers/reports/evidence/2026-10-16-p03-full-public')
out.mkdir(parents=True,exist_ok=True)
for source in scratch.iterdir():
    if source.is_dir() and (source.name.startswith(('android-matrix-','macos-matrix-','ios-matrix-','android-negative-','macos-negative-','ios-negative-')) or source.name=='android-release-diagnostic'):
        for file in source.rglob('*'):
            if not file.is_file():continue
            relative=file.relative_to(scratch)
            target=out/relative;target.parent.mkdir(parents=True,exist_ok=True)
            if file.suffix=='.log':
                target=target.with_suffix('.log.gz')
                with gzip.open(target,'wb') as stream:stream.write(file.read_bytes())
            else:shutil.copyfile(file,target)
    elif source.is_file() and source.suffix in ('.json','.md','.log','.txt','.exit','.py','.sh','.gz','.xml') and source.name not in ('commit-config.json',):
        target=out/source.name
        if source.suffix=='.log':
            target=target.with_suffix('.log.gz')
            with gzip.open(target,'wb') as stream:stream.write(source.read_bytes())
        else:shutil.copyfile(source,target)
# README is written separately after actual final runs. Manifest excludes itself.
manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file() and p.name!='manifest.json'}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(len(manifest),'evidence files')
