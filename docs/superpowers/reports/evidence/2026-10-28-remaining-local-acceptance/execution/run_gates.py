from pathlib import Path
import subprocess,json
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player');out=Path('/private/tmp/yl-local-acceptance');results=[]
for kind,script in [('performance','tool/playback_benchmark/threshold_registry.py'),('readiness','tool/release_readiness/check.py')]:
 for ready in [False,True]:
  name=kind+('-require-ready' if ready else '-structure');cmd=['python3','-B',script]+(['--require-ready'] if ready else [])
  r=subprocess.run(cmd,cwd=root,capture_output=True,text=True);(out/(name+'.log')).write_text(r.stdout+r.stderr);results.append(dict(name=name,command=cmd,exitCode=r.returncode));print(name,r.returncode)
(out/'gate-results.json').write_text(json.dumps(results,indent=2)+'\n')
