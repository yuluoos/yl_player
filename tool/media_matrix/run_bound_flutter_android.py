#!/usr/bin/env python3
"""Freeze and launch an opted-in public Flutter debug APK without rebuilding.

The test and product share one APK. The native observer verifies installed bytes,
Flutter drives the public API/view, and the independent gate verifies raw output.
This scope does not certify a release app, physical output, or the full matrix.
"""
import argparse
import base64
import gzip
import json
import subprocess
import time
import uuid
from pathlib import Path
from bound_artifacts import canonical, sha_file
from bound_av import validate
from run_bound_android import parse_rows
from run_bound_apple import CASES, PHASES, write


def planned_controls(catalog):
    """Freeze the six public controls and their expected product routes."""
    selected=[c for c in catalog if c['id'] in CASES]
    if len(selected)!=len(CASES) or {c['id'] for c in selected}!=set(CASES):
        raise ValueError('Public acceptance requires every fixed control exactly once')
    return [dict(caseId=c['id'],file=c['file'],mediaHash=c['sha256'],channels=2,
        engine='media3' if c['id'] in ('webm-vp9-vorbis','mkv-avc-flac') else 'native-fallback') for c in selected]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk',type=Path,required=True)
    parser.add_argument('--serial',required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--negative-identity',action='store_true')
    parser.add_argument('--negative-framework',action='store_true',help='Fail the Flutter test after collecting all rows')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    sha=sha_file(args.apk)
    catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
    plan=dict(schema=1,runId=str(uuid.uuid4()),platform='android',artifactKind='android-public-flutter-debug-apk',buildSha256=sha,testSha256=sha,
        planned=planned_controls(catalog),phases=PHASES)
    plan['negativeFramework']=args.negative_framework
    if args.negative_identity:plan['buildSha256']='0'*64
    write(out/'plan.json',plan)
    adb=['adb','-s',args.serial];package='dev.ylplayer.yl_player_example'
    install=subprocess.run(adb+['install','-r',str(args.apk)],capture_output=True)
    (out/'install.log').write_bytes(install.stdout+install.stderr)
    if install.returncode:raise RuntimeError('APK install failed')
    subprocess.run(adb+['shell','am','force-stop',package],check=True,capture_output=True)
    command=adb+['shell','am','start','-W','-n',package+'/'+package+'.MainActivity','--es','p03Plan',base64.b64encode(canonical(plan)).decode()]
    write(out/'launch.json',dict(command=command,preverified=sha_file(args.apk)==sha))
    started=subprocess.run(command,capture_output=True)
    (out/'launch.log').write_bytes(started.stdout+started.stderr)
    remote='files/p03-public-'+plan['runId']+'/'
    status={};deadline=time.monotonic()+150
    while time.monotonic()<deadline:
        read=subprocess.run(adb+['exec-out','run-as',package,'cat',remote+'status.json'],capture_output=True)
        try:status=json.loads(read.stdout)
        except (ValueError,UnicodeDecodeError):time.sleep(1);continue
        if isinstance(status,dict):break
    write(out/'status.json',status)
    extracted=subprocess.run(adb+['exec-out','run-as',package,'cat',remote+'rows.jsonl'],capture_output=True)
    with gzip.open(out/'extracted.jsonl.gz','wb') as stream:stream.write(extracted.stdout)
    rows,parsed=parse_rows(extracted.stdout)
    with gzip.open(out/'rows.json.gz','wb') as stream:stream.write(canonical(rows))
    log=subprocess.run(adb+['logcat','-d','-s','flutter:I','AndroidRuntime:E'],capture_output=True)
    (out/'flutter.log').write_bytes(log.stdout+log.stderr)
    result=validate(plan,rows)
    result.update(publicTestPassed=status.get('passed') is True,runtimeIdentityVerified=status.get('identityVerified') is True,
        artifactsUnchanged=sha_file(args.apk)==sha and status.get('artifactsUnchanged') is True,
        launchExit=started.returncode,extractionValid=parsed,negativeIdentity=args.negative_identity,negativeFramework=args.negative_framework)
    result['scopeAcceptance'] &= result['publicTestPassed'] and result['runtimeIdentityVerified'] and result['artifactsUnchanged'] and parsed and started.returncode==0
    write(out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2))
    return 0 if result['scopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
