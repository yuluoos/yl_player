import json,subprocess,sys
from pathlib import Path
here=Path(__file__).parent
platform=sys.argv[1]
plan=json.loads((here/f'run-{platform}.json').read_text())
with (here/f'{platform}-final-run.log').open('w') as log:
 result=subprocess.run(plan['argv'],cwd=plan['cwd'],stdout=log,stderr=log)
print(platform,result.returncode)
sys.exit(result.returncode)
