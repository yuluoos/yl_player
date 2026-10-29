from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-same-resource-retry');results=[]
for name in ['original','normal','normal-repeat','normal-third']:
 p=r/'media'/name
 cmd=['python3','-B','tool/playback_network/bandwidth_diagnostics.py','--directory',str(p),'--profiles',str(r/'profiles.json')]
 # Discover script arguments from prior verified command before use.
 old=json.loads(Path('/private/tmp/yl-cancel-settlement/bandwidth-cli-results.json').read_text())
 source=next(x for x in old if x.get('name')==('original' if name.startswith('original') else 'normal'))
 cmd=[s.replace('/private/tmp/yl-cancel-settlement','/private/tmp/yl-same-resource-retry').replace('/media/'+source['name'],'/media/'+name) for s in source['command']]
 result=subprocess.run(cmd,capture_output=True,text=True);(r/(name+'-bandwidth.stdout')).write_text(result.stdout);(r/(name+'-bandwidth.stderr')).write_text(result.stderr)
 results.append(dict(name=name,command=cmd,exitCode=result.returncode));assert result.returncode==0
(r/'bandwidth-cli-results.json').write_text(json.dumps(results,indent=2)+'\n')
