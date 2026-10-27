"""Owned Apple ABR access-log observation; does not certify adaptive policy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import threading
import time
import uuid
from xml.parsers.expat import ExpatError
from network_profile import load_profiles, make_server
from prepare_fixture import create


def summarize(rows, *, expected_duration_seconds=None, expected_transport=None, expected_startup_delay_ms=0):
    def require(value):
        if not value: raise ValueError('incomplete or invalid ABR observation')
    require(isinstance(rows,list) and 2<=len(rows)<=1000)
    require(all(isinstance(row, dict) for row in rows))
    if expected_duration_seconds is not None or expected_transport is not None:
        require(type(expected_duration_seconds) is int and expected_duration_seconds in (40, 120))
        require(expected_transport in ('managed-dash', 'direct-hls-control'))
        require(type(expected_startup_delay_ms) is int and 0 <= expected_startup_delay_ms <= 2000)
        require(all(type(row.get('programmeDurationSeconds')) is int and
                    row.get('programmeDurationSeconds') == expected_duration_seconds and
                    type(row.get('startupDelayMs')) is int and row['startupDelayMs'] == expected_startup_delay_ms and
                    row.get('transport') == expected_transport for row in rows))
        position = rows[-1].get('position')
        require(type(position) in (int, float) and math.isfinite(position) and
                position >= expected_duration_seconds - .5)
    widths=[];previous=-1
    for row in rows:
        elapsed=row['elapsed']
        require(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed>previous)
        previous=elapsed
        require(row['peak']==0 and row['status'] in (0,1))
        width=row['width'];require(type(width) in (int,float) and math.isfinite(width) and 0<=width<=16384)
        if width and (not widths or width!=widths[-1]):widths.append(width)
    require(rows[-1]['completed'] is True and type(rows[-1]['framesPublished']) is int and rows[-1]['framesPublished']>0)
    last=(rows[-1].get('logs') or [{}])[-1]
    observed=last.get('observedBitrate')
    require(observed is None or (type(observed) in (int,float) and math.isfinite(observed)))
    recovered=False;down=False
    for a,b in zip(widths,widths[1:]):
        if b<a:down=True
        elif down and b>a:recovered=True
    return dict(schemaVersion=1,geometryWidths=widths,downshiftObserved=down,
        upshiftAfterDownshiftObserved=recovered,lastObservedBitrate=observed,
        lastIndicatedBitrate=last.get('indicatedBitrate'),framesPublished=rows[-1]['framesPublished'],
        diagnosticOnly=True,internalABRDecisionVerified=False,capabilityAccepted=False,
        physicalOutputVerified=False)


def read_rows(path):
    if path.stat().st_size>16*1024*1024:raise ValueError('observation exceeds 16 MiB')
    return [json.loads(line) for line in path.read_text().splitlines()]


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
                            capture_output=True, text=True, timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError('cannot inspect owned process')
    return result.stdout.strip()


def cleanup_owned(owned):
    if owned is None:
        return False
    pid, identity = owned
    current = process_identity(pid)
    if not current:
        return True
    if current != identity:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(40):
        current = process_identity(pid)
        if not current:
            return True
        if current != identity:
            return False
        time.sleep(.1)
    return False


def observe_owned(out, token, executable):
    proof = out / 'process.json'
    if not proof.exists():
        return None
    if proof.stat().st_size > 4096:
        raise ValueError('invalid process proof')
    value = json.loads(proof.read_text())
    pid = value['pid']
    path = value['executable']
    if (value['token'] != token or type(pid) is not int or pid <= 1 or
        not isinstance(path, str) or Path(path).name != executable or '.app/' not in path):
        raise ValueError('invalid process proof')
    identity = process_identity(pid)
    if identity:
        # macOS reports the canonical /private/tmp path in ps while the native
        # host may launch through /tmp. Preserve the full start-time identity
        # for cleanup, but compare the executable's resolved path here.
        fields = identity.split(maxsplit=5)
        if (len(fields) != 6 or
                Path(fields[5]).resolve(strict=True) != Path(path).resolve(strict=True)):
            raise ValueError('process proof executable mismatch')
    return (pid, identity) if identity else None


def wait_for_native(process, command, observe, timeout=240):
    deadline = time.monotonic() + timeout
    while (code := process.poll()) is None:
        observe()
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(command, timeout)
        time.sleep(.25)
    # A child can exit during sleep, or the parent can resume after its deadline.
    # Observing exit 0 at that point is not evidence of timely completion.
    if time.monotonic() >= deadline:
        raise subprocess.TimeoutExpired(command, timeout)
    return code


def run(args):
    out=args.directory.resolve();out.mkdir(parents=True,exist_ok=False)
    receipt=dict(diagnosticOnly=True,capabilityAccepted=False,errors=[],exitCode=None)
    server=None;thread=None;process=None;log=None;output=None;owned=None
    token=uuid.uuid4().hex
    before=None;products=None
    def hashes():
        paths=[p for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')]
        return {str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    try:
        duration_seconds = getattr(args, 'duration_seconds', 40)
        direct = getattr(args, 'direct_hls_control', False)
        startup_delay_ms = getattr(args, 'startup_delay_ms', 0)
        if type(startup_delay_ms) is not int or not 0 <= startup_delay_ms <= 2000:
            raise ValueError('invalid diagnostic startup delay')
        receipt['transport'] = 'direct-hls-control' if direct else 'managed-dash'
        receipt['startupDelayMs'] = startup_delay_ms
        products=args.products.resolve(strict=True)
        manifests=list(products.glob('*.xctestrun'))
        if len(manifests)!=1:raise ValueError('expected one built test manifest')
        def absolute(value):
            if isinstance(value,str):return value.replace('__TESTROOT__',str(products))
            if isinstance(value,list):return [absolute(x) for x in value]
            if isinstance(value,dict):return {k:absolute(v) for k,v in value.items()}
            return value
        config=absolute(plistlib.loads(manifests[0].read_bytes()))
        target=config['RunnerTests']
        app=Path(target['TestHostPath'])
        if app.suffix!='.app':
            app=app.parent
            if app.name=='MacOS':app=app.parent.parent
        info=app/('Contents/Info.plist' if (app/'Contents').is_dir() else 'Info.plist')
        executable=plistlib.loads(info.read_bytes())['CFBundleExecutable']
        before=hashes();receipt['binaryHashes']=before
        receipt['fixture']=create(out/'fixture', duration_seconds=duration_seconds,
                                  direct_hls_control=direct)
        profile=load_profiles(args.profiles)[args.profile];receipt['profileSha256']=profile.sha256
        destination='platform=macOS,arch=arm64'
        if args.device:
            if not re.fullmatch('[0-9A-Fa-f-]{36}',args.device):raise ValueError('invalid simulator identifier')
            destination='platform=iOS Simulator,id='+args.device
        log=(out/'requests.jsonl').open('w');output=(out/'xcode.log').open('w')
        server=make_server(out/'fixture',profile,log,0,start_on_first_get=True,run_id='abr-accesslog')
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        target.setdefault('EnvironmentVariables',{}).update(
            YL_ABR_PROBE_TOKEN=token,YL_ABR_PROBE_URL=f'http://127.0.0.1:{server.server_port}/manifest.mpd',YL_ABR_PROBE_DIRECTORY=str(out),
            YL_ABR_PROBE_SECONDS=str(duration_seconds), YL_ABR_PROBE_DIRECT_HLS='1' if direct else '0',
            YL_ABR_PROBE_STARTUP_DELAY_MS=str(startup_delay_ms), YL_ABR_PROBE_PROFILE_SHA256=profile.sha256)
        manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
        command=['xcodebuild','test-without-building','-quiet','-xctestrun',str(manifest),
            '-destination',destination,'-only-testing:RunnerTests/YlDashResourceLoaderTests/testActualOwnedDashAdaptiveObservation',
            '-parallel-testing-enabled','NO','-resultBundlePath',str(out)+'.xcresult']
        process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            def observe():
                nonlocal owned
                if owned is None:owned=observe_owned(out,token,executable)
            receipt['exitCode']=wait_for_native(process, command, observe)
        except subprocess.TimeoutExpired:
            receipt['errors'].append('native deadline')
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
        rows=read_rows(out/'rows.jsonl')
        receipt['observation']=summarize(rows, expected_duration_seconds=duration_seconds,
                                         expected_transport=receipt['transport'], expected_startup_delay_ms=startup_delay_ms)
    except (OSError,ValueError,KeyError,TypeError,plistlib.InvalidFileException,ExpatError,
            subprocess.SubprocessError) as error:
        receipt['errors'].append(type(error).__name__)
    finally:
        if process is not None and process.poll() is None:
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=10)
        try:
            receipt['ownedProcessExited']=cleanup_owned(owned)
        except (OSError,RuntimeError,subprocess.SubprocessError):
            receipt['ownedProcessExited']=False
        if process is not None and not receipt['ownedProcessExited']:
            receipt['errors'].append('owned process cleanup unverified')
        if server:server.shutdown();server.server_close()
        if thread:thread.join(timeout=5)
        if log:log.close()
        if output:output.close()
        receipt['binaryIdentityUnchanged']=False
        if before is not None:
            try:
                receipt['binaryIdentityUnchanged']=before==hashes()
            except OSError:
                receipt['errors'].append('binary identity recheck failed')
        receipt['passed']=receipt['exitCode']==0 and not receipt['errors'] and receipt['binaryIdentityUnchanged']
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--products',type=Path,required=True);p.add_argument('--directory',type=Path,required=True)
    p.add_argument('--device',help='Explicit iOS Simulator UUID; omit for native arm64 macOS')
    p.add_argument('--profiles',type=Path,default=Path(__file__).with_name('profiles.json'))
    p.add_argument('--duration-seconds',type=int,choices=(40,120),default=40)
    p.add_argument('--startup-delay-ms',type=int,default=0,
                   help='0..2000ms diagnostic delay after arming/preparing; never changes the frozen profile')
    p.add_argument('--direct-hls-control',action='store_true',
                   help='system-only direct HLS control; not a production DASH acceptance run')
    p.add_argument('--profile',default='down-and-recover-v1');a=p.parse_args()
    result=run(a);print(json.dumps({k:v for k,v in result.items() if k!='binaryHashes'},indent=2))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
