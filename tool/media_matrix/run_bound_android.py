#!/usr/bin/env python3
"""Freeze/install a built instrumentation APK, collect same-player raw output.

Product and tests share one explicit instrumented-library APK container. This
identity must not be relabeled as a release Flutter app or physical A/V proof.
"""
import argparse
import base64
import gzip
import json
import subprocess
import uuid
from pathlib import Path
from bound_artifacts import canonical, sha_file
from bound_av import validate
from run_bound_apple import CASES, PHASES, write


def parse_rows(raw):
    """adb exec-out may return zero even when remote cat prints an error."""
    rows=[]
    try:
        for line in raw.splitlines():
            row=json.loads(line)
            if not isinstance(row,dict):return rows,False
            rows.append(row)
        return rows,bool(rows)
    except (ValueError,UnicodeDecodeError):return rows,False

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk',type=Path,required=True);parser.add_argument('--serial',required=True)
    parser.add_argument('--out',type=Path,required=True);parser.add_argument('--negative-identity',action='store_true')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    sha=sha_file(args.apk);catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
    plan=dict(schema=1,runId=str(uuid.uuid4()),platform='android',artifactKind='android-instrumented-library-apk',buildSha256=sha,testSha256=sha,
        planned=[dict(caseId=c['id'],file=c['file'],mediaHash=c['sha256'],channels=2,engine='media3' if c['id']=='webm-vp9-vorbis' else 'native-fallback') for c in catalog if c['id'] in CASES],phases=PHASES)
    if args.negative_identity:plan['buildSha256']='0'*64
    write(out/'plan.json',plan)
    adb=['adb','-s',args.serial];package='dev.ylplayer.yl_player_android.test'
    install=subprocess.run(adb+['install','-r',str(args.apk)],capture_output=True)
    (out/'install.log').write_bytes(install.stdout+install.stderr)
    if install.returncode:raise RuntimeError('APK install failed')
    cmd=adb+['shell','am','instrument','-w','-r','-e','class','dev.ylplayer.yl_player_android.YlBoundAVInstrumentedTest',
        '-e','p03Plan',base64.b64encode(canonical(plan)).decode(),package+'/androidx.test.runner.AndroidJUnitRunner']
    write(out/'launch.json',dict(command=cmd,preverified=sha_file(args.apk)==sha))
    native=subprocess.run(cmd,capture_output=True)
    (out/'native.log').write_bytes(native.stdout+native.stderr)
    extracted=subprocess.run(adb+['exec-out','run-as',package,'cat','files/p03-'+plan['runId']+'.jsonl'],capture_output=True)
    (out/'extract.log').write_bytes(extracted.stderr)
    with gzip.open(out/'extracted.jsonl.gz','wb') as stream:stream.write(extracted.stdout)
    rows,parsed=parse_rows(extracted.stdout)
    with gzip.open(out/'rows.json.gz','wb') as stream:stream.write(canonical(rows))
    result=validate(plan,rows)
    passed=native.returncode==0 and b'OK (1 test)' in native.stdout and b'FAILURES' not in native.stdout
    result.update(nativeExit=native.returncode,nativePassed=passed,artifactsUnchanged=sha_file(args.apk)==sha,extractExit=extracted.returncode,extractionValid=parsed,negativeIdentity=args.negative_identity)
    result['scopeAcceptance'] &= passed and result['artifactsUnchanged'] and extracted.returncode==0 and parsed
    write(out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2))
    return 0 if result['scopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
