from pathlib import Path
import subprocess,json,os,hashlib,sys
root=Path('/private/tmp/yl-p06-drm/yl_player');out=root/'docs/superpowers/reports/evidence/2026-10-16-p06-drm';out.mkdir(parents=True,exist_ok=True)
flutter='/Users/yy2021_8689/flutter/bin/flutter';dart='/Users/yy2021_8689/flutter/bin/cache/dart-sdk/bin/dart'
commands={
 'analyze':([flutter,'analyze','--no-pub',*['packages/yl_player/example/'+p for p in ['integration_test/drm_fault_test.dart','integration_test/drm_lifecycle_test.dart','integration_test/support/drm_acceptance_runtime.dart','integration_test/support/drm_fault_server.dart','test/drm_acceptance_runtime_test.dart','test/drm_fault_server_test.dart']]],root,0),
 'example':([flutter,'test','--no-pub','test'],root/'packages/yl_player/example',0),
 'drm':([flutter,'test','--no-pub',*sorted(str(p.relative_to(root)) for p in root.glob('packages/*/test/*drm*.dart')),'packages/yl_player/test/protected_subtitle_test.dart'],root,0),
 'cli':([sys.executable,'-B','-m','unittest','discover','-s','tool/drm_acceptance','-p','test_*.py'],root,0),
 'empty-preflight':([dart,'tool/drm_acceptance/prepare.dart','tool/drm_acceptance/inventory.example.json'],root,2),
 'private-preflight':([dart,'tool/drm_acceptance/prepare.dart','/Users/yy2021_8689/Desktop/Flutter/yl_player/.drm-acceptance-private/inventory.json'],root,2),
 'android':([flutter,'build','apk','--debug','--no-pub','-t','integration_test/drm_fault_test.dart'],root/'packages/yl_player/example',0),
}
name=sys.argv[1];args,cwd,expected=commands[name]
env=os.environ.copy();env['PATH']=str(Path(dart).parent)+os.pathsep+env['PATH'];env['JAVA_HOME']='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
log=out/(name+'.log')
with log.open('w') as f:r=subprocess.run(args,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
receipt={'command':args,'cwd':str(cwd),'exitCode':r.returncode,'expectedExitCode':expected,'logSha256':hashlib.sha256(log.read_bytes()).hexdigest()}
(out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt));print('\n'.join(log.read_text().splitlines()[-12:]))
sys.exit(0 if r.returncode==expected else 1)
