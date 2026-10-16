#!/usr/bin/env python3
"""Freeze an already-built native consumer, run without building, retain raw A/V.

This is scoped native product evidence, not a release Flutter or physical-output
certificate. Every invocation requires a new output directory, including retries.
"""
import argparse
import base64
import gzip
import json
import plistlib
import subprocess
import uuid
from pathlib import Path
from bound_artifacts import canonical, freeze, verify
from bound_av import validate

CASES={
 'ps-avc-mp3':'testProgramStreamActualPixelsPCMAndBidirectionalSeek',
 'webm-vp9-vorbis':'testNonzeroVorbisDelayActualPixelsPCMAndBidirectionalSeek',
 'mkv-avc-ac3-51':'testAC3SurroundActualPixelsSixChannelPCMAndSeek',
 'mkv-avc-eac3':'testEAC3ActualPixelsPCMAndSeek',
 'mkv-avc-dts':'testDTSActualPixelsPCMAndSeek',
 'mkv-avc-flac':'testFLACActualPixelsPCMAndSeek',
}
PHASES=[dict(phase='play',markers=[0,1,2,3]),dict(phase='seek-1250',markers=[1]),dict(phase='seek-2250',markers=[2]),dict(phase='seek-0',markers=[0])]


def write(path,value):path.write_bytes(json.dumps(value,sort_keys=True,indent=2).encode()+b'\n')
def replace_root(value,root):
    if isinstance(value,str):return value.replace('__TESTROOT__',str(root))
    if isinstance(value,list):return [replace_root(v,root) for v in value]
    if isinstance(value,dict):return {k:replace_root(v,root) for k,v in value.items()}
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctestrun',type=Path,required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--tests',type=Path,required=True)
    parser.add_argument('--platform',choices=['macos','ios'],required=True)
    parser.add_argument('--destination',required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--negative-identity',action='store_true',help='Deliberately reject a wrong product identity before playback')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    product=freeze(args.app,True);harness=freeze(args.tests)
    catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
    plan=dict(schema=1,runId=str(uuid.uuid4()),platform=args.platform,artifactKind='apple-instrumented-native-consumer',
              buildSha256=product['sha256'],testSha256=harness['sha256'],productManifest=product['manifest'],testManifest=harness['manifest'],
              planned=[dict(caseId=c['id'],mediaHash=c['sha256'],channels=c['audio']['channels']) for c in catalog if c['id'] in CASES],phases=PHASES)
    if args.negative_identity:plan['buildSha256']='0'*64
    write(out/'plan.json',plan);write(out/'product-files.json',product);write(out/'test-files.json',harness)
    config=replace_root(plistlib.loads(args.xctestrun.read_bytes()),args.xctestrun.resolve().parent)
    target=config['RunnerTests']
    target.setdefault('EnvironmentVariables',{})['YL_P03_BOUND_PLAN']=base64.b64encode(canonical(plan)).decode()
    target['OnlyTestIdentifiers']=['YlContainerOutputTests/'+v for v in CASES.values()]
    target['ParallelizationEnabled']=False
    runfile=out/'bound.xctestrun';runfile.write_bytes(plistlib.dumps(config))
    command=['xcodebuild','test-without-building','-xctestrun',str(runfile),'-destination',args.destination,'-parallel-testing-enabled','NO','-resultBundlePath',str(out/'runtime.xcresult')]
    write(out/'launch.json',dict(command=command,preverified=verify(args.app,product) and verify(args.tests,harness)))
    with (out/'native.log').open('wb') as log:exitcode=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
    stable=verify(args.app,product) and verify(args.tests,harness)
    with (out/'summary.json').open('wb') as dest:
        summary_exit=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(out/'runtime.xcresult'),'--format','json'],stdout=dest).returncode
    export=subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(out/'runtime.xcresult'),'--output-path',str(out/'attachments')],capture_output=True)
    (out/'export.log').write_bytes(export.stdout+export.stderr)
    rows=[]
    for path in sorted((out/'attachments').glob('*')):
        if not path.is_file():continue
        try:value=json.loads(path.read_bytes())
        except (ValueError,UnicodeDecodeError):continue
        if isinstance(value,dict) and 'caseId' in value and 'sessionId' in value:rows.append(value)
    with gzip.open(out/'rows.json.gz','wb') as dest:dest.write(canonical(rows))
    result=validate(plan,rows)
    result.update(nativeExit=exitcode,artifactsUnchanged=stable,summaryExit=summary_exit,exportExit=export.returncode,negativeIdentity=args.negative_identity)
    result['scopeAcceptance'] &= exitcode==0 and stable and summary_exit==0 and export.returncode==0
    write(out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2))
    return 0 if result['scopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
