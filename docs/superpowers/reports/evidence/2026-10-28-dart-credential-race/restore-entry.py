from pathlib import Path
import subprocess,json,sys,hashlib
r=Path('/private/tmp/yl-dart-credential-race');mode=sys.argv[1];cwd=Path('packages/yl_player/example').resolve();flutter='/Users/yy2021_8689/flutter/bin/flutter';target='integration_test/apple_dash_credential_failure_test.dart'
if mode in ['ios','macos']:
 name='verified-dart-'+mode;cmd=[flutter,'test',target,'-d','00008140-000C49CC3493001C' if mode=='ios' else 'macos','--no-pub','--reporter','expanded']
elif mode=='restore-ios':name=mode;cmd=[flutter,'build','ios','--debug','--config-only','--no-codesign','--no-pub','--target','lib/main.dart']
elif mode=='restore-macos':name=mode;cmd=[flutter,'build','macos','--debug','--no-pub','--target','lib/main.dart']
else:name='final-dart-analyze';cmd=[flutter,'analyze','--no-pub',target]
(r/(name+'-command.json')).write_text(json.dumps(dict(command=cmd,cwd=str(cwd)),indent=2)+'\n')
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
log=(r/(name+'.log')).read_bytes();(r/(name+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode,logSha256=hashlib.sha256(log).hexdigest(),testsPassed=(b'All tests passed!' in log) if mode in ['ios','macos'] else None),indent=2)+'\n');print(name,p.returncode,flush=True);sys.exit(p.returncode)
