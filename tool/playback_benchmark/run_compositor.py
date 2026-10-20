#!/usr/bin/env python3
"""Collect only the owned macOS example's compositor output, with numbered pixels."""
import argparse
import base64
import datetime
import json
from pathlib import Path
import platform
import subprocess
import sys
from run_public_stress import source_identity, model_label, extract
from run_resources import ROOT, EXAMPLE, run_logged, digest
from performance_gate import canonical, digest as object_digest, summarize_run
from compositor_observations import measure
from generate_capture_fixture import generate

PROTOCOL=dict(schemaVersion=1,id='owned-window-compositor-v2',windowLifecycle='hide-1s-unhide-play-and-observe',attempts=3,warmups=0,
    frameIntervalUs=100000,targetUs=5000000,targetToleranceUs=200000,stableWindowUs=1000000,
    maximumGapUs=250000,mediaDurationUs=12000000,windowContentSize=[640,400],
    captureRateHz=60,clock='mach-absolute',output='owned-window-compositor',audio='absent',
    physicalScanout=False,minimumHostOS='14.0',cacheState='os-cache-uncontrolled')


def collect(output,flutter):
    output.mkdir(parents=True,exist_ok=False)
    result=dict(schemaVersion=1,complete=False,baseline=False,releaseReady=False,stage='setup')
    try:
        source=source_identity();result['sourceFiles']=source
        media=output/'owned.mp4';generate(media)
        library=output/'capture.dylib'
        command=['xcrun','swiftc','-swift-version','5','-O','-emit-library',
            '-target',platform.machine()+'-apple-macos14.0',
            str(ROOT/'tool/playback_benchmark/capture_marker.swift'),
            str(ROOT/'tool/playback_benchmark/compositor_capture.swift'),'-o',str(library)]
        with (output/'build.log').open('w') as log:
            subprocess.run(command,check=True,timeout=60,stdout=log,stderr=log)
        deps={name:digest(ROOT/name) for name in ('pubspec.lock','pubspec.yaml','packages/yl_player/example/pubspec.yaml')}
        artifact={str(library):digest(library),str(media):digest(media),
            'packages/yl_player_media_core/tool/apple_ffmpeg/bridge-artifact.lock':digest(ROOT/'packages/yl_player_media_core/tool/apple_ffmpeg/bridge-artifact.lock')}
        context=dict(runId='p08-compositor-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'),
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            sourceHash=object_digest(source),dependencyHash=object_digest(deps),artifactHash=object_digest(artifact),
            mediaHash=digest(media),protocolHash=object_digest(PROTOCOL))
        result.update(protocol=PROTOCOL,context=context,dependencies=deps,artifacts=artifact,buildCommand=command)
        (output/'protocol.json').write_bytes(canonical(result))
        defines=output/'defines.json';defines.write_text(json.dumps(dict(YL_COMPOSITOR_CONTEXT=json.dumps(context),
            YL_CAPTURE_LIBRARY=base64.b64encode(library.read_bytes()).decode(),YL_CAPTURE_MEDIA=base64.b64encode(media.read_bytes()).decode())))
        result['stage']='playback'
        command=['env','FLUTTER_XCODE_ARCHS='+platform.machine(),flutter,'drive','-d','macos','--profile','--no-pub',
            '--driver=test_driver/integration_test.dart','--target=integration_test/compositor_benchmark_test.dart','--dart-define-from-file='+str(defines)]
        result['exitCode']=run_logged(command,EXAMPLE,output/'playback.log',600)
        raw=extract(output/'playback.log','YL_COMPOSITOR_RUN=',False)
        (output/'observations.json').write_text(json.dumps(raw,indent=2)+'\n')
        if raw['context']!=context or len(raw['trials'])!=3 or raw['captureStopped'] is not True:raise ValueError('capture identity/cleanup mismatch')
        trials=[];last_end=0
        for index,t in enumerate(raw['trials'],1):
            if t['attempt']!=index:raise ValueError('trial sequence mismatch')
            values={name:None for name in ('firstCompositorUs','seekFirstCompositorUs','seekStableCompositorUs')}
            outcome=t['outcome'];command=t['command'];rows=t['rows']
            if command and command['startUs'] is not None:
                values=measure(command,rows)
            if outcome=='passed' and (any(v is None for v in values.values()) or command.get('windowRestoreVerified') is not True):outcome='failed'
            start=rows[0]['displayUs'] if rows else last_end
            end=rows[-1]['receivedUs'] if rows else start
            last_end=end
            trials.append(dict(attempt=index,outcome=outcome,cleanup=t['cleanup'],startedUs=start,endedUs=end,values=values))
        run=dict(schemaVersion=1,**{k:v for k,v in context.items() if k not in ('mediaHash','protocolHash')},
            conditions=dict(caseId='numbered-silent-video',platform='macos',device=model_label(subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip()),
                os=platform.mac_ver()[0],architecture=platform.machine(),deviceKind='physical',buildMode='profile',power='unknown',thermal='unknown',
                output='owned-window-compositor',mediaHash=context['mediaHash'],protocolHash=context['protocolHash'],networkProfile='local-file',cacheState='os-cache-uncontrolled'),
            qualification=dict(contentVerified=False,evidenceHash=None),baselineComparable=False,plannedAttempts=3,warmupAttempts=0,
            metrics={name:dict(unit='us',boundary='compositor-capture') for name in trials[0]['values']},trials=trials)
        result['summary']=summarize_run(run)
        result['sourceUnchanged']=(source_identity()==source and
            all(digest(ROOT/name)==value for name,value in deps.items()) and
            all(digest(ROOT/name)==value for name,value in artifact.items()))
        result['complete']=result['exitCode']==0 and result['sourceUnchanged'] and result['summary']['nonPasses']==0
        (output/'run.json').write_text(json.dumps(run,indent=2)+'\n')
        result['stage']='complete'
    except (OSError,ValueError,TypeError,KeyError,subprocess.SubprocessError):result['failure']='collection-incomplete'
    finally:
        result['files']={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in output.iterdir() if p.is_file() and p.name!='result.json'}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);parser.add_argument('flutter')
    args=parser.parse_args();passed=collect(args.output.resolve(),args.flutter)
    print('Compositor observation collected.' if passed else 'Compositor run incomplete; receipt retained.')
    sys.exit(0 if passed else 1)
