#!/usr/bin/env python3
"""Collect current-host macOS public stress evidence with bounded owned execution."""
import argparse
import base64
import datetime
import json
from pathlib import Path
import platform
import subprocess
import sys

from run_resources import ROOT, EXAMPLE, digest, run_logged
from performance_gate import summarize_run, canonical, digest as object_digest, read_json


def model_label(model):
    from summarize import TOKEN
    value=model.replace(',', '-')
    if not TOKEN.fullmatch(value): raise ValueError('invalid model')
    return value


def source_identity(root=ROOT):
    names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--',
        'packages','tool/playback_benchmark','pubspec.yaml','pubspec.lock'],cwd=root,text=True).splitlines()
    # Hash all Git-visible package and benchmark inputs, including C/C++, build
    # scripts, fixtures and artifacts. Extension allowlists silently miss code.
    result={}
    for name in sorted(set(names)):
        if name == 'tool/playback_benchmark/thresholds.json': continue
        path=root/name
        if path.is_symlink():
            path.resolve(strict=True).relative_to(root.resolve())
            result[name]=object_digest({'symlink':path.readlink().as_posix()})
        elif path.is_file(): result[name]=digest(path)
    return result


def extract(log, prefix="YL_PERFORMANCE_RUN=", validate=True):
    runs=[]
    with log.open() as stream:
        for line in stream:
            if prefix not in line: continue
            raw=line.split(prefix,1)[1]
            if len(raw)>256*1024: raise ValueError('record limit')
            from summarize import unique_object, reject_constant
            runs.append(json.loads(raw,object_pairs_hook=unique_object,parse_constant=reject_constant))
            if len(runs)>1: raise ValueError('duplicate run')
    if len(runs)!=1: raise ValueError('incomplete run')
    if validate: summarize_run(runs[0])
    return runs[0]


def collect(output,flutter):
    output.mkdir(parents=True,exist_ok=False)
    result=dict(schemaVersion=1,complete=False,stage='setup',baseline=False,releaseReady=False)
    try:
        if sys.platform!='darwin': raise ValueError('host unavailable')
        protocol=read_json(ROOT/'tool/playback_benchmark/stress-protocol.json')
        source=source_identity()
        dependencies={name:digest(ROOT/name) for name in ('pubspec.yaml','pubspec.lock',
            'packages/yl_player/example/pubspec.yaml','packages/yl_player/example/macos/Podfile.lock')}
        artifact='packages/yl_player_media_core/tool/apple_ffmpeg/bridge-artifact.lock'
        native='packages/yl_player_media_core/darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge'
        artifacts={name:digest(ROOT/name) for name in (artifact,native)}
        library=output/'resources.dylib'
        subprocess.run(['sh',str(ROOT/'tool/playback_benchmark/build_apple_resources.sh'),str(library)],
            check=True,timeout=60,capture_output=True)
        artifacts[str(library)]=digest(library)
        context=dict(schemaVersion=1,runId='p08-stress-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'),
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            sourceHash=object_digest(source),dependencyHash=object_digest(dependencies),artifactHash=object_digest(artifacts),
            mediaHash=digest(ROOT/protocol['media']),platform='macos',
            device=model_label(subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip()),
            os=platform.mac_ver()[0],architecture=platform.machine(),deviceKind='physical',buildMode='profile',
            power='unknown',thermal='unknown',output='unverified',networkProfile='local-file',
            cacheState='os-cache-uncontrolled',measurement='load-to-public-first-frame-event',purpose='smoke',
            caseId='local-avc-aac-mkv',baselineComparable=True,plannedAttempts=protocol['plannedAttempts'])
        result.update(context=context,protocol=protocol,sourceFiles=source,dependencies=dependencies,artifacts=artifacts)
        (output/'protocol.json').write_bytes(canonical(result))
        defines=output/'defines.json'
        defines.write_text(json.dumps({'YL_BENCHMARK_CONTEXT':json.dumps(context),
            'YL_STRESS_PROTOCOL_HASH':object_digest(protocol),
            'YL_RESOURCE_LIBRARY_BYTES':base64.b64encode(library.read_bytes()).decode()}))
        command=['env','FLUTTER_XCODE_ARCHS='+platform.machine(),flutter,'drive','-d','macos','--profile','--no-pub',
            '--driver=test_driver/integration_test.dart','--target=integration_test/playback_stress_test.dart',
            '--dart-define-from-file='+str(defines)]
        result['stage']='playback'
        result['exitCode']=run_logged(command,EXAMPLE,output/'playback.log',protocol['commandTimeoutSeconds'])
        run=extract(output/'playback.log')
        # The device cannot silently replace the frozen run/build/media identity.
        if any(run[k]!=context[k] for k in ('runId','commit','sourceHash','dependencyHash','artifactHash','plannedAttempts')):
            raise ValueError('identity mismatch')
        if run['conditions']['protocolHash']!=object_digest(protocol): raise ValueError('protocol mismatch')
        raw_resources=extract(output/'playback.log','YL_STRESS_RESOURCES=',False)
        from stress_resources import attach
        run,resource_summary=attach(run,raw_resources)
        (output/'resources.json').write_text(json.dumps(raw_resources,indent=2)+'\n')
        result['resources']=resource_summary
        result['resourceCollectionComplete']=all(t['unavailableSamples']==0 and
            t['phases'].get('playing',{}).get('cpuOneCorePercent',{}).get('coveredUs',0)>0 and
            t['phases'].get('disposed',{}).get('sampledWindowUs',0)>=500000
            for t in resource_summary['trials'])
        (output/'run.json').write_text(json.dumps(run,indent=2)+'\n')
        result['summary']=summarize_run(run)
        result['sourceUnchanged']=source_identity()==source and all(digest(ROOT/n)==v for n,v in dependencies.items()) and all(digest(ROOT/n)==v for n,v in artifacts.items())
        result['complete']=result['exitCode']==0 and result['summary']['nonPasses']==0 and result['sourceUnchanged'] and result['resourceCollectionComplete']
        result['stage']='complete'
    except (OSError,ValueError,TypeError,KeyError,RecursionError,subprocess.SubprocessError):
        result['failure']='collection-incomplete'
    finally:
        result['files']={p.name:{'sha256':digest(p),'bytes':p.stat().st_size}
            for p in output.iterdir() if p.is_file() and p.name!='result.json'}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path);parser.add_argument('flutter')
    args=parser.parse_args()
    try: passed=collect(args.output.resolve(),args.flutter)
    except OSError:
        print('A fresh output directory is required.',file=sys.stderr);return 2
    print('Stress collected; no physical output or SLO admission.' if passed else 'Stress incomplete; evidence retained.')
    return 0 if passed else 1

if __name__=='__main__':sys.exit(main())
