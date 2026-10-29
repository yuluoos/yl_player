import sys,json,hashlib,subprocess
from pathlib import Path
r=Path('/private/tmp/yl-recovery-landing');name=sys.argv[1]
paths=subprocess.check_output(['git','ls-files','packages/yl_player_apple/darwin','packages/yl_player_media_core/darwin','tool/consumer_fixtures/apple_flutter/RunnerTests','packages/yl_player/example/ios/RunnerTests','packages/yl_player/example/macos/RunnerTests','tool/consumer_fixtures/apple_flutter/main_example_tests.py'],text=True).splitlines()
hashes={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths if Path(p).is_file()}
(r/(name+'-source.json')).write_text(json.dumps(hashes,indent=2)+'\n')
(r/(name+'-diff.patch')).write_text(subprocess.check_output(['git','diff','a240032b'],text=True))
print(name,len(hashes))
