from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-postcommit-failure');p=r/'dart-ios-drive.log'
(r/'dart-ios-drive-result.json').write_text(json.dumps(dict(exitCode=0,testsExecuted=False,outcome='manually-interrupted-before-test-after-vm-service-discovery-timeout',deviceTransport='localNetwork',logSha256=hashlib.sha256(p.read_bytes()).hexdigest()),indent=2)+'\n')
(r/'dart-ios-drive-command.json').write_text(json.dumps(dict(command=['/Users/yy2021_8689/flutter/bin/flutter','drive','--driver=test_driver/integration_test.dart','--target=integration_test/apple_dash_credential_failure_test.dart','-d','00008140-000C49CC3493001C','--no-pub','--publish-port'],cwd=str(Path('packages/yl_player/example').resolve())),indent=2)+'\n')
