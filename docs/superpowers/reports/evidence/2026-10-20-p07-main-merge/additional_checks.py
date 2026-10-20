from pathlib import Path
import os,subprocess,json,time
root=Path.cwd();out=Path('/private/tmp/p07-main-merge-20261020');env=os.environ.copy()
python='/Users/yy2021_8689/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
env['PATH']=str(Path(python).parent)+':/Users/yy2021_8689/flutter/bin:'+env['PATH'];env['FLUTTER_ROOT']='/Users/yy2021_8689/flutter'
checks=[
 ('hdr',['sh','tool/apple_hdr/run_tests.sh'],0),
 ('metal',['bash','tool/apple_hdr/run_fel_compositor_tests.sh'],0),
 ('airplay',[python,'-B','tool/airplay/run_module_tests.py','--build-dir',str(out/'airplay-build'),'--live-fixture'],0),
 ('delivery',[python,'-B','tool/media_delivery/run_native_tests.py','--build-dir',str(out/'delivery-build')],0),
 ('header-parity',[python,'-B','tool/media_delivery/run_header_parity_tests.py','--build-dir',str(out/'header-build')],0),
 ('rust',['env','CARGO_HOME='+str(root/'.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/cargo-home'),'RUSTC='+str(root/'.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/rust-sysroot/bin/rustc'),'CARGO_TARGET_DIR=/private/tmp/p07-engineering-20261020/inspector-build/target','cargo','test','--locked','--offline','--release','--manifest-path','/private/tmp/p07-engineering-20261020/inspector-build/inspector/Cargo.toml'],0),
 ('real-regressions',[python,'-B',str(out/'real_regressions.py')],0),
 ('threshold-registry',[python,'-B','tool/playback_benchmark/threshold_registry.py'],0),
 ('p08-readiness',['sh','tool/check_p08.sh','--require-ready'],1),
 ('release-readiness-required',[python,'-B','tool/release_readiness/check.py','--require-ready'],1),
]
results=[]
for name,cmd,expected in checks:
    start=time.monotonic()
    with (out/(name+'.txt')).open('wb') as log:
        result=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
    entry={'name':name,'command':cmd,'exit':result.returncode,'expected_exit':expected,'seconds':time.monotonic()-start,'log':name+'.txt'}
    results.append(entry);(out/'additional-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(f'{name}: exit={result.returncode}, expected={expected}',flush=True)
    if result.returncode!=expected:raise SystemExit(1)
