"""Reproducible macOS resource smoke; fresh output, no production admission."""
import base64
import datetime
import hashlib
import json
import os
import signal
from pathlib import Path
import shutil
import subprocess
import sys
from resources import summarize_trials

ROOT=Path(__file__).resolve().parents[2]
EXAMPLE=ROOT/'packages/yl_player/example'
HERE=Path(__file__).resolve().parent


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def run_logged(command, cwd, path, timeout):
    with path.open('w') as log:
        process=subprocess.Popen(command,cwd=cwd,stdout=log,stderr=log,start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            # Only this runner's process group; never search/kill by app name.
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: pass
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait(timeout=2)
            raise


def collect(output, flutter):
    output.mkdir(parents=True,exist_ok=False)
    run='macos-resource-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    result=dict(schemaVersion=1,runId=run,runStatus='failed',stage='setup',purpose='instrumentation-smoke',
                performanceBaseline=False,budgetAdmission=False,physicalOutput='not_verified',
                cacheState='os-cache-uncontrolled',networkProfile='local-file',buildMode='debug')
    try:
        paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--','packages','tool/playback_benchmark'],cwd=ROOT,text=True).splitlines()
        source={n:digest(ROOT/n) for n in sorted(set(paths)) if Path(n).suffix in (
            '.dart','.swift','.m','.h','.kt','.py','.sh','.pbxproj','.xcconfig',
            '.podspec','.plist','.entitlements','.yaml','.lock') or Path(n).name=='Podfile'}
        dependencies={n:digest(ROOT/n) for n in ['pubspec.yaml','pubspec.lock',
            'packages/yl_player/example/pubspec.yaml','packages/yl_player/example/macos/Podfile.lock']}
        artifact='packages/yl_player_apple/tool/apple_ffmpeg/bridge-artifact.lock'
        result.update(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            sourceFingerprints=source,sourceHash=hashlib.sha256(json.dumps(source,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
            dependencies=dependencies,artifactLockSha256=digest(ROOT/artifact),
            mediaHash=digest(EXAMPLE/'assets/test_media/format_matrix/mkv-avc-aac.mkv'),
            device=dict(model=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),
                cpu=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
                os=subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),
                osBuild=subprocess.check_output(['sw_vers','-buildVersion'],text=True).strip()))
        result['stage']='sampler-build'
        library=output/'resources.dylib'
        with (output/'sampler-build.log').open('w') as log:
            subprocess.run(['sh',str(HERE/'build_apple_resources.sh'),str(library)],stdout=log,stderr=log,timeout=60,check=True)
        result['samplerSha256']=digest(library)
        defines=output/'defines.json'
        defines.write_text(json.dumps(dict(YL_RESOURCE_RUN_ID=run,YL_RESOURCE_LIBRARY_BYTES=base64.b64encode(library.read_bytes()).decode()))+'\n')
        result['stage']='playback'
        command=[flutter,'test','integration_test/resource_benchmark_test.dart','-d','macos','--no-pub','--dart-define-from-file='+str(defines)]
        exit_code=run_logged(command,EXAMPLE,output/'playback.log',600)
        result['flutterExitCode']=exit_code
        trials=[]
        for line in (output/'playback.log').read_text().splitlines():
            if 'YL_RESOURCE_SERIES=' in line: trials.append(json.loads(line.split('YL_RESOURCE_SERIES=',1)[1]))
        (output/'observations.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in trials))
        result['stage']='classification';result['summary']=summarize_trials(trials)
        assert all(t['runId']==run and t['buildMode']=='debug' for t in trials)
        result.update(runStatus='collected' if exit_code==0 else 'playback_failed',stage='complete',observations=trials)
    except (OSError,ValueError,TypeError,KeyError,AssertionError,subprocess.SubprocessError):
        pass
    finally:
        result['logs']={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in output.glob('*.log')}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['runStatus']=='collected'


def main():
    if len(sys.argv) not in (2,3):
        print('Usage: run_resources.py NEW_DIRECTORY [FLUTTER_EXECUTABLE]',file=sys.stderr);return 2
    flutter=sys.argv[2] if len(sys.argv)==3 else shutil.which('flutter')
    if not flutter:
        print('Flutter executable is required.',file=sys.stderr);return 2
    try: passed=collect(Path(sys.argv[1]).resolve(),flutter)
    except OSError:
        print('A fresh writable result directory is required.',file=sys.stderr);return 2
    print('Resource smoke collected; no budget or baseline is admitted.' if passed else
          'Resource smoke incomplete or failed; raw evidence retained.')
    return 0 if passed else 2

if __name__=='__main__':sys.exit(main())
