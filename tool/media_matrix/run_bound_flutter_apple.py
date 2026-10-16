#!/usr/bin/env python3
"""Freeze an Apple public Flutter debug bundle; launch without rebuilding.

The test Dart code shares the product bundle. Native code verifies all frozen
files and loaded product images before playback. Framework-final status and raw
same-session output must both pass. No release/physical/full-matrix claim.
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
from bound_av import validate
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
    result['scopeAcceptance'] &= all(result[k] for k in ('publicTestPassed','runtimeIdentityVerified','artifactsUnchanged','statusRunMatches'))
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--platform',choices=['macos','ios'],required=True)
    parser.add_argument('--simulator',help='Dedicated simulator UUID, required for iOS')
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--negative-identity',action='store_true')
    parser.add_argument('--negative-framework',action='store_true')
    args=parser.parse_args();app=args.app.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    if args.platform=='ios' and not args.simulator:parser.error('--simulator required for iOS')
    product=freeze(app,True)
    catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
    plan=dict(schema=1,runId=str(uuid.uuid4()),platform=args.platform,artifactKind='apple-public-flutter-debug-app',
        buildSha256=product['sha256'],testSha256=product['sha256'],productManifest=product['manifest'],
        planned=planned_controls(catalog),phases=PHASES,negativeFramework=args.negative_framework)
    if args.negative_identity:plan['buildSha256']='0'*64
    write(out/'plan.json',plan);write(out/'product-files.json',product)
    encoded=base64.b64encode(canonical(plan)).decode()
    plist=plistlib.loads((app/('Contents/Info.plist' if args.platform=='macos' else 'Info.plist')).read_bytes())
    environment={**os.environ,'NSUnbufferedIO':'YES'}
    if args.platform=='macos':
        command=[str(app/'Contents/MacOS'/plist['CFBundleExecutable'])]
        environment['YL_P03_BOUND_PLAN']=encoded
    else:
        subprocess.run(['xcrun','simctl','install',args.simulator,str(app)],check=True,capture_output=True)
        command=['xcrun','simctl','launch','--console-pty','--terminate-running-process',args.simulator,plist['CFBundleIdentifier']]
        environment['SIMCTL_CHILD_YL_P03_BOUND_PLAN']=encoded
        environment['SIMCTL_CHILD_NSUnbufferedIO']='YES'
    write(out/'launch.json',dict(command=command,preverified=verify(app,product)))
    status={};rows=[];remote=None
    with (out/'flutter.log').open('wb') as log:
        process=subprocess.Popen(command,env=environment,stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+180
            while time.monotonic()<deadline:
                content=(out/'flutter.log').read_text(errors='replace')
                for line in content.splitlines():
                    if line.startswith('YL_BOUND_RESULT='):
                        candidate=Path(line.split('=',1)[1].strip())
                        if candidate.name=='p03-public-'+plan['runId']:remote=candidate
                if remote and (remote/'status.json').is_file():
                    status=json.loads((remote/'status.json').read_bytes())
                    if not isinstance(status,dict):status={}
                    if (remote/'rows.json').is_file():rows=json.loads((remote/'rows.json').read_bytes())
                    break
                if process.poll() is not None:break
                time.sleep(0.5)
        finally:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            if args.platform=='ios':
                subprocess.run(['xcrun','simctl','terminate',args.simulator,plist['CFBundleIdentifier']],capture_output=True)
    # Preserve partial rows even when framework completion never arrives.
    if remote and (remote/'rows.json').is_file():rows=json.loads((remote/'rows.json').read_bytes())
    if remote and (remote/'unfinished.json').is_file():
        (out/'unfinished.json').write_bytes((remote/'unfinished.json').read_bytes())
    write(out/'status.json',status)
    with gzip.open(out/'rows.json.gz','wb') as stream:stream.write(canonical(rows))
    result=acceptance(plan,rows,status,verify(app,product))
    result.update(processExit=process.returncode,negativeIdentity=args.negative_identity,negativeFramework=args.negative_framework)
    write(out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2))
    return 0 if result['scopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
