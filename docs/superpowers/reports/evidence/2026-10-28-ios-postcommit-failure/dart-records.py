from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-postcommit-failure');cwd=str(Path('packages/yl_player/example').resolve());flutter='/Users/yy2021_8689/flutter/bin/flutter';target='integration_test/apple_dash_credential_failure_test.dart';device='00008140-000C49CC3493001C'
rows=[('dart-macos',1,[flutter,'test',target,'-d','macos','--no-pub','--reporter','expanded']),('dart-macos-events',0,[flutter,'test',target,'-d','macos','--no-pub','--reporter','expanded']),('dart-ios',1,[flutter,'test',target,'-d',device,'--no-pub','--reporter','expanded']),('dart-ios-wireless',64,[flutter,'test',target,'-d',device,'--no-pub','--publish-port','--reporter','expanded'])]
for name,code,cmd in rows:
 p=r/(name+'.log');(r/(name+'-receipt.json')).write_text(json.dumps(dict(command=cmd,cwd=cwd,exitCode=code,logSha256=hashlib.sha256(p.read_bytes()).hexdigest(),phase='before-final-review-fix'),indent=2)+'\n')
