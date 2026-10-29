from pathlib import Path
import json,subprocess,hashlib
r=Path('/private/tmp/yl-production-races');p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift');s=p.read_text();old='''    guard permitted else {
      scheduleVideoConstraintFailure(generation: policy.generation, seekRevision: seekRevision)''';assert old in s;s=s.replace(old,'''    guard permitted else {
      // This current-authority violation already latched blocked under the lock.
      // A later seek must not suppress its terminal notification.
      scheduleVideoConstraintFailure(generation: policy.generation)''');p.write_text(s)
original=p.read_bytes();mutated=original.replace(b',\n        seekRevision.map({ self.userSeekRevision == $0 }) ?? true else',b' else');assert mutated!=original
(r/'fixed-error-mutant.swift').write_bytes(mutated)
cmd=[x.replace('raster-red.xcresult','fixed-error-mutation-red.xcresult') for x in json.loads((r/'raster-red-command.json').read_text())];(r/'fixed-error-mutation-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
try:
 p.write_bytes(mutated)
 with (r/'fixed-error-mutation-red.log').open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 (r/'fixed-error-mutation-red-result.json').write_text(json.dumps(dict(exitCode=result.returncode,mutation='Remove asynchronous fixed-frame failure seek revision guard',restoredSourceSha256=hashlib.sha256(original).hexdigest()))+'\n');print('fixed-error-mutation-red',result.returncode)
finally:p.write_bytes(original)
