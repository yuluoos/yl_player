from pathlib import Path
import subprocess,json,sys,hashlib,os
r=Path('/private/tmp/yl-dart-credential-race');mode=sys.argv[1];name=sys.argv[2] if len(sys.argv)>2 else mode;cwd=Path('packages/yl_player/example').resolve();flutter='/Users/yy2021_8689/flutter/bin/flutter';target='integration_test/apple_dash_credential_race_test.dart';env=os.environ.copy()
if mode=='analyze':cmd=[flutter,'analyze','--no-pub',target]
elif mode=='macos':cmd=[flutter,'test',target,'-d','macos','--no-pub','--reporter','expanded']
elif mode=='ios':
 cmd=['/Users/yy2021_8689/flutter/bin/cache/dart-sdk/bin/dart','--packages=/Users/yy2021_8689/flutter/packages/flutter_tools/.dart_tool/package_config.json',str(r/'flutter_arm_iproxy.dart'),'test',target,'-d','00008140-000C49CC3493001C','--no-pub','--reporter','expanded'];env['FLUTTER_ROOT']='/Users/yy2021_8689/flutter'
elif mode=='unit':cmd=[flutter,'test','test/apple_player_controller_test.dart','test/player_controller_test.dart','--no-pub','--reporter','expanded'];cwd=Path('packages/yl_player').resolve()
else:raise ValueError(mode)
(r/(name+'-command.json')).write_text(json.dumps(dict(command=cmd,cwd=str(cwd)),indent=2)+'\n')
source=Path('packages/yl_player/example')/target;(r/(name+'-source.dart')).write_bytes(source.read_bytes())
with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
log=(r/(name+'.log')).read_bytes();(r/(name+'-result.json')).write_text(json.dumps(dict(exitCode=p.returncode,logSha256=hashlib.sha256(log).hexdigest(),testSourceSha256=hashlib.sha256((r/(name+'-source.dart')).read_bytes()).hexdigest(),testsPassed=b'All tests passed!' in log),indent=2)+'\n');print(name,p.returncode,flush=True);sys.exit(p.returncode)
