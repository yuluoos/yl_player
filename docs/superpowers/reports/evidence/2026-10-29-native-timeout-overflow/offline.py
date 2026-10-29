from pathlib import Path
import subprocess,re,json
r=Path('/private/tmp/yl-timeout-overflow')
mods=sorted(set(re.findall(r'\((test_[^.]+)\.',Path('/private/tmp/yl-half-close-fix/tools.log').read_text())))
cmds=[('tools',['python3','-B','-m','unittest','-v',*mods],'tool/playback_benchmark'),('consumer',['python3','-B','-m','unittest','discover','-v'], 'tool/consumer_fixtures/apple_flutter'),('registry',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py'],None)]
rows=[]
for name,cmd,cwd in cmds:
 with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
 rows.append(dict(name=name,command=cmd,cwd=cwd,exitCode=p.returncode));print(name,p.returncode,flush=True)
(r/'offline-results.json').write_text(json.dumps(rows,indent=2)+'\n')
