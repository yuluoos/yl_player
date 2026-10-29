from pathlib import Path
import hashlib,json,subprocess,gzip,sys
root=Path(sys.argv[1]); evidence=root/'docs/superpowers/reports/evidence/2026-10-28-remaining-local-acceptance'
candidate=json.loads((evidence/'execution/candidate-snapshot.json').read_text())
for name,h in candidate['files'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==h,name
names=[]
for line in (evidence/'SHA256SUMS').read_text().splitlines():
 h,name=line.split('  ',1);p=evidence/name;assert hashlib.sha256(p.read_bytes()).hexdigest()==h,name
 if p.suffix=='.gz':gzip.decompress(p.read_bytes())
 names.append(name)
assert set(names)=={p.relative_to(evidence).as_posix() for p in evidence.rglob('*') if p.is_file() and p.name!='SHA256SUMS'}
subprocess.run(['git','diff','--check'],cwd=root,check=True)
print(json.dumps(dict(candidateFiles=len(candidate['files']),evidenceFiles=len(names),hashesMatch=True,allGzipValid=True)))
