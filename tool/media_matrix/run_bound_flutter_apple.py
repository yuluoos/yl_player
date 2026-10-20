#!/usr/bin/env python3
"""Freeze an Apple public Flutter debug bundle; launch without rebuilding.

The test Dart code shares the product bundle. Native code verifies all frozen
files and loaded product images before playback. Framework-final status and raw
same-session output must both pass. Physical-device transport is explicit; no release/full-matrix claim.
"""
import argparse
import base64
import gzip
import json
import os
import plistlib
import subprocess
import time
import uuid
from pathlib import Path
from bound_artifacts import canonical, freeze, verify
from bound_device import DeviceTransport
from bound_av import validate, validate_render_pull
from bound_matrix import planned_case
from run_bound_apple import CASES, PHASES, write


def planned_controls(catalog):
    """Preserve the fixed six-case denominator, including unsupported rows."""
    selected=[c for c in catalog if c['id'] in CASES]
    if len(selected)!=len(CASES) or {c['id'] for c in selected}!=set(CASES):
        raise ValueError('Apple public acceptance requires every fixed control exactly once')
    return [dict(caseId=c['id'],file=c['file'],mediaHash=c['sha256'],channels=c['audio']['channels']) for c in selected]


def acceptance(plan, rows, status, stable):
    """A passed raw gate cannot hide framework failure or changed bundle bytes."""
    result=validate(plan,rows)
    result.update(publicTestPassed=status.get('passed') is True,
        runtimeIdentityVerified=status.get('identityVerified') is True,
        artifactsUnchanged=stable and status.get('artifactsUnchanged') is True,
        statusRunMatches=status.get('runId')==plan['runId'])
    trusted=all(result[k] for k in ('publicTestPassed','runtimeIdentityVerified','artifactsUnchanged','statusRunMatches'))
    result['scopeAcceptance'] &= trusted
    if any(isinstance(row,dict) and row.get('audioClockMethod')=='avplayer-preeffects-source-pull' for row in rows):
        pull=validate_render_pull(plan,rows)
        result.update(renderPullAcceptance=pull['renderPullAcceptance'] and trusted,
            renderPullErrors=pull['errors'], renderPullRows=pull['supportedRows'])
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--platform',choices=['macos','ios'],required=True)
    target=parser.add_mutually_exclusive_group()
    target.add_argument('--simulator',help='Dedicated iOS simulator UUID')
    target.add_argument('--device',help='Explicit physical iPhone UDID')
    parser.add_argument('--flutter',default='flutter',help='Flutter executable for physical Debug launch')
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--case',dest='case_id',help='One catalog cell; used by the fixed complete-matrix runner')
    parser.add_argument('--transport',choices=['file','http'],default='file')
    parser.add_argument('--matrix-id',default=None)
    parser.add_argument('--negative-identity',action='store_true')
    parser.add_argument('--negative-framework',action='store_true')
    args=parser.parse_args()
    if not args.case_id and (args.transport!='file' or args.matrix_id):parser.error('--case required for transport/matrix selection')
    app=args.app.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    if args.platform=='ios' and not (args.simulator or args.device):parser.error('--simulator or --device required for iOS')
    if args.platform!='ios' and (args.simulator or args.device):parser.error('device targets require --platform ios')
    product=freeze(app,True)
    catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
    plan=dict(schema=1,runId=str(uuid.uuid4()),platform=args.platform,artifactKind='apple-public-flutter-debug-app',
        buildSha256=product['sha256'],testSha256=product['sha256'],productManifest=product['manifest'],
        planned=[planned_case(catalog,args.case_id,args.platform,args.transport)] if args.case_id else planned_controls(catalog),phases=PHASES,negativeFramework=args.negative_framework)
    plan['executionTarget']=dict(kind='physical' if args.device else 'simulator' if args.simulator else 'host',id=args.device or args.simulator or 'macos')
    if args.matrix_id:plan['matrixId']=args.matrix_id
    if args.negative_identity:plan['buildSha256']='0'*64
    write(out/'plan.json',plan);write(out/'product-files.json',product)
    encoded=base64.b64encode(canonical(plan)).decode()
    plist=plistlib.loads((app/('Contents/Info.plist' if args.platform=='macos' else 'Info.plist')).read_bytes())
    environment={**os.environ,'NSUnbufferedIO':'YES'}
    device=None;cleanup=True;collector_error=None
    if args.device:
        device=DeviceTransport(args.device,plist['CFBundleIdentifier'],plan['runId'],out)
        device.prepare(app,encoded)
        command=device.launch_command(args.flutter,app)
    elif args.platform=='macos':
        command=[str(app/'Contents/MacOS'/plist['CFBundleExecutable'])]
        environment['YL_P03_BOUND_PLAN']=encoded
    else:
        subprocess.run(['xcrun','simctl','install',args.simulator,str(app)],check=True,capture_output=True)
        command=['xcrun','simctl','launch','--console-pty','--terminate-running-process',args.simulator,plist['CFBundleIdentifier']]
        environment['SIMCTL_CHILD_YL_P03_BOUND_PLAN']=encoded
        environment['SIMCTL_CHILD_NSUnbufferedIO']='YES'
    write(out/'launch.json',dict(command=command,preverified=verify(app,product)))
    status={};rows=[];remote=None;collection_completed=False
    with (out/'flutter.log').open('wb') as log:
        process=subprocess.Popen(command,env=environment,stdout=log,stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if device else None,
            cwd=Path(__file__).resolve().parents[2]/'packages/yl_player/example' if device else None)
        try:
            deadline=time.monotonic()+(240 if device else 180)
            while time.monotonic()<deadline:
                if device:
                    current=device.read_json('status.json')
                    if current is not None:
                        status=current
                        if device.has_started(out/'flutter.log'):
                            collection_completed=True
                            break
                    if process.poll() is not None:
                        collector_error='process_exited_before_completion'
                        break
                    time.sleep(2)
                    continue
                content=(out/'flutter.log').read_text(errors='replace')
                for line in content.splitlines():
                    if line.startswith('YL_BOUND_RESULT='):
                        candidate=Path(line.split('=',1)[1].strip())
                        if candidate.name=='p03-public-'+plan['runId']:remote=candidate
                if remote and (remote/'status.json').is_file():
                    status=json.loads((remote/'status.json').read_bytes())
                    if not isinstance(status,dict):status={}
                    if (remote/'rows.json').is_file():rows=json.loads((remote/'rows.json').read_bytes())
                    collection_completed=True
                    break
                if process.poll() is not None:
                    collector_error='process_exited_before_completion'
                    break
                time.sleep(0.5)
            else:
                collector_error='collection_timeout'
        except (ValueError,OSError,subprocess.SubprocessError) as error:
            collector_error=type(error).__name__
        finally:
            if device:cleanup=device.stop(process,out/'flutter.log')
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            if args.simulator:
                subprocess.run(['xcrun','simctl','terminate',args.simulator,plist['CFBundleIdentifier']],capture_output=True)
    # Preserve partial rows even when framework completion never arrives.
    if device:
        try:
            rows=device.read_json('rows.json') or []
            unfinished=device.read_json('unfinished.json')
            if unfinished is not None:write(out/'unfinished.json',unfinished)
        except (ValueError,OSError,subprocess.SubprocessError) as error:
            collector_error=type(error).__name__
    if remote and (remote/'rows.json').is_file():rows=json.loads((remote/'rows.json').read_bytes())
    if remote and (remote/'unfinished.json').is_file():
        (out/'unfinished.json').write_bytes((remote/'unfinished.json').read_bytes())
    write(out/'status.json',status)
    with gzip.open(out/'rows.json.gz','wb') as stream:stream.write(canonical(rows))
    result=acceptance(plan,rows,status,verify(app,product) and cleanup and collection_completed and collector_error is None)
    result.update(collectionCompleted=collection_completed,deviceCleanupCompleted=cleanup if device else None,collectorError=collector_error,executionTarget=plan['executionTarget'])
    result.update(processExit=process.returncode,negativeIdentity=args.negative_identity,negativeFramework=args.negative_framework)
    write(out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2))
    return 0 if result['scopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
