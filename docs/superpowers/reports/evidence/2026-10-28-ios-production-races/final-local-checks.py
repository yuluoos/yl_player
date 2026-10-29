from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-production-races');checks=[('network',['python3','-B','-m','unittest','discover','-s','tool/playback_network','-p','test_*.py','-v']),('consumer',['python3','-B','-m','unittest','discover','-s','tool/consumer_fixtures/apple_flutter','-p','test_*.py','-v']),('current-targets',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py','--current-only']),('historical-targets',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py','--historical-only']),('historical-source',['sh','packages/yl_player_apple/tool/check_source_parity.sh'])];results=[]
for name,cmd in checks:
 with (r/('final-'+name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode));(r/'final-local-checks.json').write_text(json.dumps(results,indent=2)+'\n');print(name,p.returncode,flush=True)
