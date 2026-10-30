from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-final-media-budget');rows=[]
for name,cmd,cwd in [('tools',['python3','-B','-m','unittest','discover','-s','tool/playback_network','-v'],None),('consumer',['python3','-B','-m','unittest','discover','-v'],'tool/consumer_fixtures/apple_flutter'),('registry',['python3','-B','tool/consumer_fixtures/apple_flutter/main_example_tests.py'],None)]:
 with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
 rows.append(dict(name=name,command=cmd,cwd=cwd,exitCode=p.returncode));print(name,p.returncode,flush=True)
(r/'offline-results.json').write_text(json.dumps(rows,indent=2)+'\n')
assert all(x['exitCode']==0 for x in rows)
