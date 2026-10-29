from pathlib import Path
import subprocess,json,hashlib
r=Path('/private/tmp/yl-abr-main-merge');checks=[('network',['python3','-B','-m','unittest','discover','-s','tool/playback_network','-p','test_*.py','-v']),('consumer',['python3','-B','-m','unittest','discover','-s','tool/consumer_fixtures/apple_flutter','-p','test_*.py','-v']),('current-targets',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py','--current-only']),('historical-targets',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py','--historical-only']),('source-parity',['sh','packages/yl_player_apple/tool/check_source_parity.sh']),('ledger-tests',['python3','-B','-m','unittest','discover','-s','tool/playback_benchmark','-p','test_release_readiness.py','-v'])]
results=[]
for name,cmd in checks:
 with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append(dict(name=name,command=cmd,exitCode=p.returncode));print(name,p.returncode,flush=True)
(r/'test-results.json').write_text(json.dumps(results,indent=2)+'\n');assert all(x['exitCode']==0 for x in results)
identity=json.loads(Path('docs/superpowers/reports/evidence/2026-10-29-ios-transaction-metrics/source-identity.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in identity.items());print('ABR source inputs unchanged',len(identity))
