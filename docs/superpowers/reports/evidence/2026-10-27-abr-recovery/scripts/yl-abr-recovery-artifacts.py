import hashlib,json,time
from pathlib import Path
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-acceptance/yl_player')
out=Path('/private/tmp/yl-abr-recovery-20261027-runs')
seen=set();deadline=time.monotonic()+2400
while len(seen)<6 and time.monotonic()<deadline:
 for run in sorted(out.glob('*-auto-*-r*')):
  if run.name in seen:continue
  trace=run/'requests.jsonl'
  if not trace.exists() or '"method": "GET"' not in trace.read_text():continue
  if run.name.startswith('ios'):
   base=root/'packages/yl_player/example/build/ios/iphonesimulator/Runner.app'
   files=[p for p in base.rglob('*') if p.is_file() and not p.is_symlink()]
  else:
   base=root/'packages/yl_player/example/build/app/outputs/flutter-apk'
   files=[base/'app-debug.apk']
  hashes={str(p.relative_to(base)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
  (run/'artifact-files.json').write_text(json.dumps({'base':str(base),'phase':'first successful GET observed during active run','files':hashes},indent=2)+'\n')
  seen.add(run.name)
 time.sleep(2)
print(json.dumps({'captured':sorted(seen)}),flush=True)
