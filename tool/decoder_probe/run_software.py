"""Fixed fresh-process software measurement; never automatic device admission.

A new directory is mandatory. Compile, bind exact installed images and freeze
protocol.json before launching any control or measured process. Failed raw logs
remain immutable. Process CPU includes internal decoder workers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid
from software_evidence import summarize

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
FRAMEWORK=ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64'
BRIDGE=FRAMEWORK/'YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge'


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n')


def decode_raw(text):
    """Require every flushed raw sample to match the final process result."""
    try:
        lines=[json.loads(line) for line in text.splitlines()]
        if len(lines)!=66:raise ValueError('incomplete raw process')
        samples=[line['sample'] for line in lines[:-1]]
        if [s['slot'] for s in samples]!=list(range(65)):raise ValueError('duplicate or reordered raw samples')
        result=lines[-1]
        if result['samples']!=samples:raise ValueError('result differs from raw observations')
        return result
    except (KeyError,TypeError,json.JSONDecodeError) as error:
        raise ValueError('invalid raw process') from error


def valid_control(control):
    """Validate actual control output before any measured process may start."""
    expected={(policy,g) for policy in ('systemDefault','hardwarePreferred','hardwareRequired') for g in (0,1)}
    if not isinstance(control,list) or len(control)!=6 or any(not isinstance(r,dict) for r in control):return False
    if any(type(r.get('generation')) is not int for r in control):return False
    if {(r.get('policy'),r.get('generation')) for r in control}!=expected:return False
    return all(r.get('caseId')=='avc-control' and r.get('createStatus')==0 and
        r.get('hardwareEvidence')=='hardware' and r.get('outputFrames')==96 and
        r.get('callbackErrors')==0 and r.get('geometryErrors')==0 and
        all(r.get(k)==0 for k in ('decodeStatus','finishStatus','waitStatus')) for r in control)


def collect(template, output):
    output.mkdir(parents=True,exist_ok=False)
    result=dict(runStatus='failed',stage='inputs',productionEnabled=False,rows=[])
    try:
        protocol=json.loads(template.read_text())
        fixed=dict(schemaVersion=1,repetitions=5,idleNs=2_000_000_000,decodeNs=12_000_000_000,
                   disposeNs=2_000_000_000,sampleIntervalNs=250_000_000,maxSampleLatenessNs=50_000_000,
                   buildMode='release',simulator=False,fixture='av1-main8',threads=2,sustainedThermalVerified=False)
        if any(type(protocol.get(k)) is not type(v) or protocol[k]!=v for k,v in fixed.items()):
            raise ValueError('protocol differs from fixed executable')
        if protocol.get('ownershipLimits')!=dict(maxOwnedBytes=33554432,maxFrames=64,maxPacketBytes=1048576):
            raise ValueError('ownership limits differ from fixed executable')
        manifest=json.loads((HERE/'fixtures/manifest.json').read_text())
        inputs={r['caseId']:r for r in manifest['cases']}
        for name in ['av1-main8','avc-control']:
            item=inputs[name]
            if digest(HERE/'fixtures'/item['fixture'])!=item['sha256'] or digest(ROOT/item['ownedSource'])!=item['ownedSourceSha256']:
                raise ValueError('fixture identity changed')
        sources=[HERE/'software_decode_probe.swift',HERE/'apple_decode_probe.swift',HERE/'run_software.py',HERE/'software_evidence.py',template]
        result['sourceSha256']={str(p.relative_to(ROOT)):digest(p) for p in sources}
        result['stage']='compile'
        common=['xcrun','swiftc','-O','-module-cache-path',str(output/'module-cache')]
        with (output/'build.log').open('w') as log:
            subprocess.run(common+['-F',str(FRAMEWORK),'-framework','YlFFmpegBridge','-Xlinker','-rpath','-Xlinker',str(FRAMEWORK),
                                  str(HERE/'software_decode_probe.swift'),'-o',str(output/'probe')],stdout=log,stderr=log,timeout=120,check=True)
            subprocess.run(common+[str(HERE/'apple_decode_probe.swift'),'-o',str(output/'control')],stdout=log,stderr=log,timeout=120,check=True)
        protocol['key']=dict(model=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),
            osBuild=subprocess.check_output(['sysctl','-n','kern.osversion'],text=True).strip(),
            decoderBuild=digest(output/'probe')+':'+digest(BRIDGE),codec=12,profile=0,bitDepth=8,chroma=420,
            width=320,height=180,fpsNumerator=24,fpsDenominator=1,threads=2,outputPixelFormat=875704438)
        protocol['fixtureSha256']=inputs['av1-main8']['sha256']
        protocol['ownedMediaSha256']=inputs['av1-main8']['ownedSourceSha256']
        protocol['positiveControlBuildSha256']=digest(output/'control')
        save(output/'protocol.json',protocol)  # Immutable before first process.
        protocol_hash=hashlib.sha256(canonical(protocol)).hexdigest()
        result['protocolSha256']=protocol_hash
        result['stage']='positive-control'
        with (output/'control.jsonl').open('w') as raw,(output/'control.stderr').open('w') as errors:
            subprocess.run([str(output/'control'),str(HERE/'fixtures/avc-control.json')],stdout=raw,stderr=errors,timeout=30,check=True)
        control=[json.loads(line) for line in (output/'control.jsonl').read_text().splitlines()]
        if not valid_control(control):raise ValueError('actual AVC positive control failed')
        result['positiveControlSha256']=digest(output/'control.jsonl')
        result['stage']='measure'
        for index in range(5):
            raw=output/f'run-{index}.jsonl'
            try:
                with raw.open('w') as log,(output/f'run-{index}.stderr').open('w') as errors:
                    subprocess.run([str(output/'probe'),str(HERE/'fixtures/av1-main8.json'),str(ROOT/inputs['av1-main8']['ownedSource'])],
                                   stdout=log,stderr=errors,timeout=25,check=True)
                row=decode_raw(raw.read_text())
            except (ValueError,OSError,subprocess.SubprocessError) as error:
                row=dict(status='failed',collectionFailure=type(error).__name__)
            row.update(run=index,runId=uuid.uuid4().hex,rawSha256=digest(raw),protocolSha256=protocol_hash,
                       key=protocol['key'],fixtureSha256=protocol['fixtureSha256'],buildMode='release',simulator=False,
                       positiveControlPassed=True,positiveControlSha256=result['positiveControlSha256'])
            result['rows'].append(row)
            save(output/'result.json',result)
        result['summary']=summarize(protocol,result['rows'])
        # Freeze/source checks cannot repair identity after a changed build.
        if protocol['key']['decoderBuild']!=digest(output/'probe')+':'+digest(BRIDGE):raise ValueError('binary changed during run')
        if result['sourceSha256']!={str(p.relative_to(ROOT)):digest(p) for p in sources}:raise ValueError('sources changed during run')
        result.update(runStatus='collected' if result['summary']['measurementValid'] else 'failed',stage='complete')
    except (ValueError,OSError,subprocess.SubprocessError) as error:
        result['collectionFailure']=type(error).__name__
    finally:save(output/'result.json',result)
    return result


def check_admission(baseline, verification):
    """Read-only: reject reused/incomplete runs and absent sustained evidence.

    This short engineering protocol does not implement or invent thermal limits.
    A future sustained evidence provider must qualify the actual product binary;
    a probe binary hash cannot admit the Flutter app or a different OS/device.
    """
    if baseline.resolve()==verification.resolve():raise ValueError('verification must be independent')
    summaries=[]; protocols=[]; run_ids=set(); raw_hashes=set()
    for root in (baseline,verification):
        result=json.loads((root/'result.json').read_text());protocol=json.loads((root/'protocol.json').read_text())
        protocol_hash=hashlib.sha256(canonical(protocol)).hexdigest()
        if result.get('runStatus')!='collected' or result.get('protocolSha256')!=protocol_hash:
            raise ValueError('incomplete or changed protocol')
        protocols.append(protocol)
        for row in result['rows']:
            if type(row.get('run')) is not int or row['run'] not in range(5):raise ValueError('invalid run index')
            raw=root/f"run-{row['run']}.jsonl"
            if digest(raw)!=row['rawSha256']:raise ValueError('raw evidence changed')
            actual=decode_raw(raw.read_text())
            if any(row.get(k)!=v for k,v in actual.items()):raise ValueError('summary differs from raw process')
            if row.get('runId') in run_ids or row['rawSha256'] in raw_hashes:
                raise ValueError('verification reused a measured process')
            run_ids.add(row.get('runId'));raw_hashes.add(row['rawSha256'])
        control=root/'control.jsonl'
        if (digest(control)!=result.get('positiveControlSha256') or
            not valid_control([json.loads(line) for line in control.read_text().splitlines()]) or
            any(row.get('positiveControlSha256')!=digest(control) for row in result['rows'])):
            raise ValueError('positive control evidence changed')
        summary=summarize(protocol,result['rows'])
        if not summary['measurementValid']:raise ValueError('invalid measurement')
        summaries.append(summary)
    if protocols[0]!=protocols[1]:raise ValueError('verification changed the frozen profile or inputs')
    blockers=sorted(set(x for s in summaries for x in s['admissionBlockers'])-{'independent_verification_missing'})
    return dict(productionEligible=False,admissionBlockers=blockers)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('protocol',type=Path);parser.add_argument('output',type=Path)
    parser.add_argument('--check-admission',action='store_true',help='treat positional paths as baseline and verification directories; write nothing')
    args=parser.parse_args()
    try:
        if args.check_admission:
            print(json.dumps(check_admission(args.protocol,args.output)));return 2
        result=collect(args.protocol.resolve(),args.output.resolve())
        print(json.dumps({k:result[k] for k in ('runStatus','stage','productionEnabled')}))
        return 0 if result['runStatus']=='collected' else 2
    except (ValueError,OSError) as error:
        print(f'No evidence overwritten: {error}',file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
