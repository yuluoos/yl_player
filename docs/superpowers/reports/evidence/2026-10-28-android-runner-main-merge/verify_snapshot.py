from pathlib import Path
import sys,json,hashlib,gzip,subprocess
root=Path(sys.argv[1]);e=root/'docs/superpowers/reports/evidence/2026-10-28-android-acceptance-deadlines';candidate=json.loads((e/'candidate-snapshot.json').read_text())
for n,h in candidate['files'].items():assert hashlib.sha256((root/n).read_bytes()).hexdigest()==h,n
names=[]
for row in (e/'SHA256SUMS').read_text().splitlines():
 h,n=row.split('  ',1);p=e/n;assert hashlib.sha256(p.read_bytes()).hexdigest()==h,n
 if p.suffix=='.gz':gzip.decompress(p.read_bytes())
 names.append(n)
assert set(names)=={p.relative_to(e).as_posix() for p in e.rglob('*') if p.is_file() and p.name!='SHA256SUMS'}
subprocess.run(['git','diff','--check'],cwd=root,check=True)
print(json.dumps(dict(candidateFiles=len(candidate['files']),evidenceFiles=len(names),hashesMatch=True,gzipValid=True)))
