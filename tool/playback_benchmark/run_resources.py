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
import time
from resources import summarize_trials, summarize_disposed_memory, summarize_endurance

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


def collect(output, flutter, *, profile_cycles=False, harness_only=False, lifetime_probes=False, endurance=False, long_lifetime_probes=False):
    if long_lifetime_probes and (not profile_cycles or harness_only or lifetime_probes or endurance):
        raise ValueError("Long lifecycle diagnostics require separate profile playback")
    extended=endurance or long_lifetime_probes
    if endurance and (not profile_cycles or harness_only or lifetime_probes):
        raise ValueError("Endurance requires profile playback without diagnostic checkpoints")
    if harness_only and not profile_cycles:
        raise ValueError('Harness control requires profile cycles')
    if lifetime_probes and (not profile_cycles or harness_only):
        raise ValueError('Lifetime checkpoints require profile playback')
    workload='harness-only' if harness_only else 'playback'
    output.mkdir(parents=True,exist_ok=False)
    attempts=100 if extended else 10 if profile_cycles else 3
    mode='profile' if profile_cycles else 'debug'
    run='macos-resource-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    result=dict(schemaVersion=2,workload=workload,lifetimeProbes=lifetime_probes,runId=run,runStatus='failed',stage='setup',purpose='load-dispose-endurance' if endurance else 'instrumentation-smoke',
                performanceBaseline=False,budgetAdmission=False,physicalOutput='not_verified',
                cacheState='os-cache-uncontrolled',networkProfile='local-file',buildMode=mode,plannedAttempts=attempts,
                protocol=dict(idleSeconds=2,playingUntilMediaSeconds=None if harness_only else 2,
                              lifetimeCheckpointSeconds=20 if lifetime_probes else None,
                              playingWallSeconds=2 if harness_only else None,disposedSeconds=2,intervalMs=250))
    if extended:
        result['protocol'].update(minimumObservationSeconds=600, testTimeoutSeconds=900,
                                  commandTimeoutSeconds=1200, continuousPlayback=False,
                                  stopAfterFailure=True, plannedAttempts=100)
    if long_lifetime_probes:
        result.update(purpose='long-cycle-lifetime-diagnostics',longLifetimeProbes=True)
        result['protocol'].update(lifetimeCheckpointSeconds=30,lifetimeProtocol='long-cycle-v1',
                                  lifetimeWindows=[[1,'live'],[10,'disposed'],[50,'disposed'],[100,'disposed']],
                                  observers=['heap --noContent','vmmap -summary'],observerTimeoutSeconds=10)
    try:
        paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--','packages','tool/playback_benchmark'],cwd=ROOT,text=True).splitlines()
        source={n:digest(ROOT/n) for n in sorted(set(paths)) if Path(n).suffix in (
            '.dart','.swift','.m','.h','.kt','.py','.sh','.pbxproj','.xcconfig',
            '.podspec','.plist','.entitlements','.yaml','.lock') or Path(n).name=='Podfile'}
        dependencies={n:digest(ROOT/n) for n in ['pubspec.yaml','pubspec.lock',
            'packages/yl_player/example/pubspec.yaml','packages/yl_player/example/macos/Podfile.lock']}
        artifact='packages/yl_player_apple/tool/apple_ffmpeg/bridge-artifact.lock'
        native='packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge'
        result['artifactFingerprints']={native:digest(ROOT/native),artifact:digest(ROOT/artifact)}
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
        defines.write_text(json.dumps(dict(YL_RESOURCE_RUN_ID=run,YL_RESOURCE_PROFILE_CYCLES=profile_cycles,YL_RESOURCE_HARNESS_ONLY=harness_only,YL_RESOURCE_LIFETIME_PROBES=lifetime_probes,YL_RESOURCE_ENDURANCE=endurance,YL_RESOURCE_LONG_LIFETIME_PROBES=long_lifetime_probes,YL_RESOURCE_LIBRARY_BYTES=base64.b64encode(library.read_bytes()).decode()))+'\n')
        result['stage']='playback'
        command=[flutter,'test','integration_test/resource_benchmark_test.dart','-d','macos','--no-pub','--dart-define-from-file='+str(defines)]
        if profile_cycles:
            architecture=subprocess.check_output(['uname','-m'],text=True).strip()
            if architecture not in ('arm64','x86_64'): raise ValueError('Unsupported host architecture')
            result['architecture']=architecture
            command=['env','FLUTTER_XCODE_ARCHS='+architecture,flutter,'drive','-d','macos','--profile','--no-pub',
                '--driver=test_driver/integration_test.dart','--target=integration_test/resource_benchmark_test.dart',
                '--dart-define-from-file='+str(defines)]
        result['command']=command
        if extended:
            # Freeze identities/protocol before the measured process starts.
            protocol=output/'protocol.json'
            protocol.write_text(json.dumps(result,indent=2)+'\n')
            result['protocolSha256']=digest(protocol)
        started=time.monotonic()
        try:
            exit_code=run_logged(command,EXAMPLE,output/'playback.log',1200 if extended else 600)
        except subprocess.TimeoutExpired:
            exit_code=None
            result['commandFailure']='timeout'
        result['commandElapsedSeconds']=time.monotonic()-started
        result['flutterExitCode']=exit_code
        trials=[]
        for line in (output/'playback.log').read_text().splitlines():
            if 'YL_RESOURCE_SERIES=' in line: trials.append(json.loads(line.split('YL_RESOURCE_SERIES=',1)[1]))
        (output/'observations.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in trials))
        result['observations']=trials
        result['stage']='classification';result['summary']=summarize_trials(trials)
        assert all(t['runId']==run and t['buildMode']==mode and t['plannedAttempts']==attempts and t.get('workload')==workload and t['schemaVersion']==2 for t in trials)
        if profile_cycles: result['disposedMemory']=summarize_disposed_memory(trials)
        if extended: result['endurance']=summarize_endurance(trials)
        result['sourceIdentityVerified']=all(digest(ROOT/p)==v for p,v in source.items())
        assert result['sourceIdentityVerified']
        result.update(runStatus='collected' if exit_code==0 and (not extended or result['endurance']['protocolCompleted']) else 'playback_failed',stage='complete',observations=trials)
    except (OSError,ValueError,TypeError,KeyError,AssertionError,subprocess.SubprocessError):
        pass
    finally:
        result['logs']={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in output.glob('*.log')}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['runStatus']=='collected'


def main():
    args=sys.argv[1:]
    endurance=bool(args and args[0]=='--profile-endurance')
    harness_only=bool(args and args[0]=='--profile-control')
    profile_cycles=bool(args and args[0] in ('--profile-cycles','--profile-control','--profile-endurance'))
    if profile_cycles: args=args[1:]
    if len(args) not in (1,2):
        print('Usage: run_resources.py [--profile-cycles | --profile-control | --profile-endurance] NEW_DIRECTORY [FLUTTER_EXECUTABLE]',file=sys.stderr);return 2
    flutter=args[1] if len(args)==2 else shutil.which('flutter')
    if not flutter:
        print('Flutter executable is required.',file=sys.stderr);return 2
    try: passed=collect(Path(args[0]).resolve(),flutter,profile_cycles=profile_cycles,harness_only=harness_only,endurance=endurance)
    except OSError:
        print('A fresh writable result directory is required.',file=sys.stderr);return 2
    print('Resource observations collected; no budget or baseline is admitted.' if passed else
          'Resource observations incomplete or failed; raw evidence retained.')
    return 0 if passed else 2

if __name__=='__main__':sys.exit(main())
