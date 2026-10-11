"""Run one owned native-output activation observation; preserve failures and identities."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
from collect_timed_video import evaluate, number


def validate_run(observation, activation, run, *, candidate=True):
    result=evaluate(observation, require_stall=False, require_candidate=candidate, require_audio_clock=run.get("audioClockProtocolRequired") is True)
    errors=result['failures']
    if run.get('exceptions'): errors.append('runner exception preserved')
    if run.get('exitCode')!=0: errors.append('native process failed')
    if run.get('unchanged') is not True: errors.append('source/binary identity changed')
    if run.get('ownedProcessExited') is not True: errors.append('owned process cleanup incomplete')
    rows=observation.get('rows', [])
    if run.get('threadPerformanceCheckerRemoved') is True and (not rows or any(row.get('runtimeDiagnostics',{}).get('threadPerformanceCheckerLoaded') is not False for row in rows)):
        errors.append('thread checker removal lacks runtime proof')
    first=next((r for r in rows if r.get('phase')=='playing'), {})
    final=next((r for r in rows if r.get('phase')=='activeEnd'), {})
    requested=activation.get('requested')
    if (activation.get('exitCode')!=0 or activation.get('returnedPID')!=final.get('pid')
        or activation.get('sameOwnedPID') is not True or activation.get('active') is not True):
        errors.append('external activation did not reuse the exact owned PID')
    valid_time=number(requested) and first.get('uptime',float('inf'))<=requested<=final.get('uptime',0)
    if not valid_time: errors.append('activation request missing or outside observation')
    events=final.get('activationEvents', [])
    if not valid_time or not any(e.get('name')=='NSApplicationDidBecomeActiveNotification' and
        requested<=e.get('uptime',0)<=final.get('uptime',0) for e in events):
        errors.append('actual didBecomeActive notification missing after request')
    drops=final.get('dropEvents', [])
    before=sum(e['count'] for e in drops if valid_time and e['uptime']<requested)
    after=sum(e['count'] for e in drops if valid_time and e['uptime']>=requested)
    complete=valid_time and before+after==final.get('applicationDrops')
    if not complete: errors.append('drop history cannot be completely classified')
    result.update(passed=not errors, dropClassification=dict(before=before,after=after,complete=complete), productionAdmission=False)
    return result


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def identities(root, app):
    files=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
    prefixes=('packages/yl_player_apple/','packages/yl_player/example/macos/','tool/playback_benchmark/','tool/run_with_display_awake.py')
    sources={name:digest(root/name) for name in files if name.startswith(prefixes) and (root/name).is_file() and not (root/name).is_symlink()}
    # Include current untracked test/collector sources as well, never keys/secrets.
    for directory in ['tool/playback_benchmark','packages/yl_player_apple/darwin']:
        for path in (root/directory).rglob('*'):
            if path.suffix in {'.py','.swift'} and path.is_file() and not path.is_symlink(): sources[str(path.relative_to(root))]=digest(path)
    fixture=root/'packages/yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv'
    sources[str(fixture.relative_to(root))]=digest(fixture)
    binaries={str(path):digest(path) for path in app.rglob('*') if path.is_file() and not path.is_symlink()}
    return dict(sourceHashes=sources,binaryHashes=binaries)


def read_rows(path):
    if not path.exists(): return []
    lines=path.read_text().splitlines();rows=[]
    for index,line in enumerate(lines):
        try: rows.append(json.loads(line))
        except json.JSONDecodeError:
            if index!=len(lines)-1: raise
    return rows


def remove_thread_performance_checker(config):
    # Mutate only this invocation's copied manifest, preserving XCTest injection
    # and Main Thread Checker. The project/scheme keeps its diagnostic defaults.
    for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
        env = config['RunnerTests'].get(key, {})
        libraries = env.get('DYLD_INSERT_LIBRARIES', '').split(':')
        remaining = [path for path in libraries if path and Path(path).name != 'libRPAC.dylib']
        if remaining: env['DYLD_INSERT_LIBRARIES'] = ':'.join(remaining)
        else: env.pop('DYLD_INSERT_LIBRARIES', None)
        for name in list(env):
            if name.startswith('PERFC_'): del env[name]

def collect(args):
    root=Path(__file__).resolve().parents[2]; out=args.directory.resolve();out.mkdir(parents=True,exist_ok=False)
    products=args.products.resolve();app=products/args.configuration/'yl_player_example.app'
    identity=identities(root,app)
    (out/'identity.json').write_text(json.dumps(identity,indent=2))
    helper=out/'activate-owned'
    subprocess.run(['xcrun','swiftc',str(root/'tool/playback_benchmark/activate_owned_macos.swift'),'-o',str(helper)],check=True)
    manifests=list(products.glob('*.xctestrun'))
    if len(manifests)!=1: raise ValueError('Require exactly one arm64 test manifest')
    config=plistlib.loads(manifests[0].read_bytes().replace(b'__TESTROOT__',str(products).encode()))
    config['RunnerTests']['EnvironmentVariables'].update(YL_TIMED_TRANSPORT_DIAGNOSTICS='1' if getattr(args,'transport_diagnostics',False) else '0',YL_TIMED_CANDIDATE='1' if args.candidate else '0',YL_TIMED_DIRECTORY=str(out),YL_TIMED_LONG='1' if args.long else '0',YL_TIMED_DIAGNOSTICS='1' if getattr(args,'diagnostics',False) else '0',YL_TIMED_REVEAL='1' if getattr(args,'reveal',False) else '0',YL_TIMED_ALLOW_OCCLUSION='1' if getattr(args,'allow_occlusion',False) else '0')
    if getattr(args,'without_thread_checker',False): remove_thread_performance_checker(config)
    manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
    limit=1320 if args.long else 180
    cmd=[sys.executable,'-B',str(root/'tool/run_with_display_awake.py'),'xcodebuild','test-without-building','-quiet','-xctestrun',str(manifest),'-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO','-only-testing:RunnerTests/YlMacosAudioTests/testActualTimedNativeActivationObservation','-test-timeouts-enabled','YES','-default-test-execution-time-allowance',str(limit-30),'-maximum-test-execution-time-allowance',str(limit-30),'-resultBundlePath',str(out)+'.xcresult']
    (out/'command.json').write_text(json.dumps(cmd,indent=2))
    (out/'protocol.json').write_text(json.dumps(dict(audioClockProtocolRequired=True,configuration=args.configuration,candidate=args.candidate,diagnostics=getattr(args,'diagnostics',False),transportDiagnostics=getattr(args,'transport_diagnostics',False),revealAt20Seconds=getattr(args,'reveal',False),visibleWindowProtocol=not getattr(args,'allow_occlusion',False),seconds=1200 if args.long else 30,activationAtSeconds=10,instruments=False,threadPerformanceCheckerRemoved=getattr(args,'without_thread_checker',False),physicalOutputProven=False,productionAdmission=False),indent=2))
    activation={}; owned_pid=None; reason='native completion';start=time.monotonic();first_seen=None; code=-1; errors=[]
    with (out/'xcode.log').open('w') as log:
        process=subprocess.Popen(cmd,cwd=root,stdout=log,stderr=log)
        try:
            while process.poll() is None:
                if first_seen is None:
                    rows=read_rows(out/'rows.jsonl');playing=[r for r in rows if r['phase']=='playing']
                    if playing:
                        owned_pid=playing[0]['pid']
                        first_seen=time.monotonic()
                if first_seen is not None and not activation and time.monotonic()-first_seen>=10:
                    receipt=subprocess.run([str(helper),str(owned_pid),str(app)],capture_output=True,text=True,timeout=10)
                    activation=dict(exitCode=receipt.returncode,stdout=receipt.stdout,stderr=receipt.stderr)
                    match=re.search(r'pid=(\d+) requested=([\d.]+) returned=([\d.]+).*active=(true|false) sameOwnedPID=(true|false)',receipt.stdout)
                    if match: activation.update(returnedPID=int(match[1]),requested=float(match[2]),returned=float(match[3]),active=match[4]=='true',sameOwnedPID=match[5]=='true')
                    (out/'activation.json').write_text(json.dumps(activation,indent=2))
                if time.monotonic()-start>limit:
                    reason='parent timeout';process.terminate();break
                time.sleep(.2)
            code=process.wait(timeout=15)
        except (Exception, KeyboardInterrupt) as error:
            reason='observation exception';errors.append(repr(error))
            if not activation:
                def decoded(value): return value.decode(errors='replace') if isinstance(value,bytes) else value or ''
                activation=dict(exitCode=None,error=repr(error),stdout=decoded(getattr(error,'stdout',None)),stderr=decoded(getattr(error,'stderr',None)))
                (out/'activation.json').write_text(json.dumps(activation,indent=2))
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired as error: errors.append(repr(error))
            if code == -1 and process.poll() is not None: code=process.poll()
    process_command=''
    try:
        if owned_pid:
            process_command=subprocess.run(['ps','-p',str(owned_pid),'-o','command='],capture_output=True,text=True,timeout=5).stdout.strip()
            if str(app/'Contents/MacOS/yl_player_example') in process_command:
                os.kill(owned_pid,signal.SIGTERM);time.sleep(1)
                process_command=subprocess.run(['ps','-p',str(owned_pid),'-o','command='],capture_output=True,text=True,timeout=5).stdout.strip()
    except Exception as error:
        errors.append(repr(error));process_command='cleanup unverified'
    changed=[name for name,sha in {**identity['sourceHashes'],**identity['binaryHashes']}.items() if not (root/name).is_file() or digest(root/name)!=sha]
    run=dict(audioClockProtocolRequired=True,exitCode=code,unchanged=not changed,changed=changed,ownedPID=owned_pid,ownedProcessExited=owned_pid is not None and not process_command,reason=reason,exceptions=errors,threadPerformanceCheckerRemoved=getattr(args,'without_thread_checker',False),elapsed=time.monotonic()-start)
    (out/'run.json').write_text(json.dumps(run,indent=2))
    try:
        observation=json.loads((out/'observation.json').read_text()) if (out/'observation.json').exists() else dict(rows=read_rows(out/'rows.jsonl'))
    except Exception as error:
        run['exceptions'].append(repr(error));observation={}
        (out/'run.json').write_text(json.dumps(run,indent=2))
    result=validate_run(observation,activation,run,candidate=args.candidate)
    (out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2),flush=True)
    return result['passed']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products',type=Path,required=True)
    parser.add_argument('--configuration',choices=['Debug','Profile'],required=True)
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--candidate',action='store_true')
    parser.add_argument('--long',action='store_true')
    parser.add_argument('--allow-occlusion',action='store_true',help='Diagnostic legacy normal-window placement only')
    parser.add_argument('--reveal',action='store_true',help='Diagnostic intervention: raise the owned video test window at20s')
    parser.add_argument('--without-thread-checker',action='store_true',help='Controlled measurement without injected Thread Performance Checker; retains other diagnostics')
    parser.add_argument('--transport-diagnostics',action='store_true',help='Read bounded transport state without per-second system metrics; diagnostic only')
    parser.add_argument('--diagnostics',action='store_true',help='Per-second system metrics and bounded timing samples; diagnostic only')
    return 0 if collect(parser.parse_args()) else 1

if __name__=='__main__': raise SystemExit(main())
