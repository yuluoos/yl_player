from pathlib import Path
import json,subprocess,sys
out=Path('/private/tmp/yl-public-transport');previous=Path('docs/superpowers/reports/evidence/2026-10-28-ios-policy-intent')
mode=sys.argv[1];cmd=json.loads((previous/(mode+'-contracts-command.json')).read_text())
cmd=[x.replace('/private/tmp/yl-continuity-macos','/private/tmp/yl-public-policy-macos').replace('/private/tmp/yl-boundary-device-build','/private/tmp/yl-public-policy-ios').replace('/private/tmp/yl-policy-intent/',str(out)+'/') for x in cmd]
cmd[cmd.index('-resultBundlePath')+1]=str(out/('final-'+mode+'-contracts.xcresult'))
cmd+=['-only-testing:RunnerTests/YlNetworkRequestPolicyTests']
(out/('final-'+mode+'-contracts-command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
with (out/('final-'+mode+'-contracts.log')).open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(out/('final-'+mode+'-contracts-result.json')).write_text(json.dumps({'exitCode':p.returncode})+'\n');print(mode,p.returncode,flush=True)
for key in ['summary','tests']:
 r=subprocess.run(['xcrun','xcresulttool','get','test-results',key,'--path',str(out/('final-'+mode+'-contracts.xcresult'))],capture_output=True,text=True)
 (out/('final-'+mode+'-contracts-'+key+'.json')).write_text(r.stdout)
