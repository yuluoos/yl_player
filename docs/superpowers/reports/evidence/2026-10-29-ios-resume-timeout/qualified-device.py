from pathlib import Path
import subprocess,json
r=Path('/private/tmp/yl-resume-timeout');old=Path('docs/superpowers/reports/evidence/2026-10-28-ios-production-races')
def run(name,cmd):
 (r/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
 with (r/(name+'.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 (r/(name+'-result.json')).write_text(json.dumps({'exitCode':p.returncode})+'\n');print(name,p.returncode,flush=True)
 return p.returncode
cmd=json.loads((old/'qualified-ios-command.json').read_text());cmd=[v.replace('/private/tmp/yl-public-policy-ios','/private/tmp/yl-recovery-landing/ios-build') for v in cmd]
if run('qualified-ios-build',cmd):raise SystemExit(1)
products=Path('/private/tmp/yl-recovery-landing/ios-build/Build/Products');runs=list(products.glob('*.xctestrun'));assert len(runs)==1
cmd=json.loads((old/'qualified-device-contracts-command.json').read_text());cmd=[str(runs[0]) if v.endswith('.xctestrun') else v.replace('/private/tmp/yl-production-races/qualified-device-contracts.xcresult',str(r/'qualified-device.xcresult')) for v in cmd]
run('qualified-device',cmd)
for kind in ['summary','tests']:
 p=subprocess.run(['xcrun','xcresulttool','get','test-results',kind,'--path',str(r/'qualified-device.xcresult')],capture_output=True,text=True)
 (r/('qualified-device-'+kind+'.json')).write_text(p.stdout)
