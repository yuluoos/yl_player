"""Run a frozen, bounded native decoded observation; retain failed prefixes."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from decoded_continuity import validate, diagnose_drops
from run_audio_integration_resources import ROOT, digest, freeze
from run_resources import run_logged


def require_short_gate(directory, identity):
    if directory is None:raise ValueError('Long arm requires short evidence')
    directory=Path(directory)
    prior=json.loads((directory/'result.json').read_text())
    if prior.get('complete') is not True or prior.get('kind')!='short' or prior.get('exitCode')!=0:
        raise ValueError('Short gate did not pass')
    if json.loads((directory/'identity.json').read_text())!=identity:
        raise ValueError('Short gate identity differs')
    validate([json.loads(line) for line in (directory/'rows.jsonl').read_text().splitlines()],30)


def collect(kind, directory, short_evidence=None):
    out=Path(directory).resolve();out.mkdir(parents=True,exist_ok=False)
    result=dict(complete=False,kind=kind,errors=[],productionAdmission=False,downstreamBoundProven=False)
    identity=None
    try:
        products=ROOT/'packages/yl_player/example/build/native-macos-tests/Build/Products'
        identity=freeze(out,products)
        for relative in ['tool/playback_benchmark/decoded-continuity-protocol.md',
                         'tool/playback_benchmark/aac-preroll-protocol.md',
                         'tool/playback_benchmark/video-drop-diagnostics-protocol.md',
                         'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Clock/YlFrameScheduler.swift',
                         'packages/yl_player/example/macos/RunnerTests/YlMacosVideoTests.swift',
                         'tool/playback_benchmark/decoded_continuity.py','tool/playback_benchmark/test_decoded_continuity.py',
                         'tool/playback_benchmark/run_decoded_continuity.py',
                         'tool/playback_benchmark/run_resources.py','tool/run_with_display_awake.py',
                         'packages/yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv']:
            path=ROOT/relative;identity['sourceHashes'][relative]=digest(path)
            if path.suffix!='.mkv':(out/'sources'/path.name).write_bytes(path.read_bytes())
        (out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
        if kind=='long':
            require_short_gate(short_evidence,identity)
            result['shortGateEvidence']=str(Path(short_evidence).resolve())
        fixture=ROOT/'packages/yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv'
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(fixture)],text=True,timeout=20))
        (out/'media.json').write_text(json.dumps(probe,indent=2)+'\n')
        if not 1259<=float(probe['format']['duration'])<=1261 or [s['codec_name'] for s in probe['streams']]!=['h264','aac']:
            raise ValueError('Unexpected fixture')
        def absolute(value):
            if isinstance(value,str):return value.replace('__TESTROOT__',str(products))
            if isinstance(value,list):return [absolute(x) for x in value]
            if isinstance(value,dict):return {k:absolute(v) for k,v in value.items()}
            return value
        manifests=list(products.glob('*.xctestrun'))
        if len(manifests)!=1:raise ValueError('Ambiguous native manifest')
        config=absolute(plistlib.loads(manifests[0].read_bytes()));target=config['RunnerTests']
        for env in (os.environ,target.get('EnvironmentVariables',{}),target.get('TestingEnvironmentVariables',{})):
            if any(k.startswith('MallocStackLogging') for k in env):raise ValueError('MSL must be absent')
        target.setdefault('EnvironmentVariables',{}).update(YL_DECODED_PROBE_KIND=kind,YL_DECODED_PROBE_DIRECTORY=str(out))
        manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
        command=[sys.executable,'-B',str(ROOT/'tool/run_with_display_awake.py'),'xcodebuild','test-without-building','-quiet',
            '-xctestrun',str(manifest),'-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO',
            '-only-testing:RunnerTests/YlMacosAudioTests/testActualDecodedTerminalContinuousObservation',
            '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','1380' if kind=='long' else '90',
            '-default-test-execution-time-allowance','1380' if kind=='long' else '90','-resultBundlePath',str(out)+'.xcresult']
        (out/'command.json').write_text(json.dumps(command,indent=2)+'\n')
        try:result['exitCode']=run_logged(command,ROOT,out/'xcode.log',1500 if kind=='long' else 180)
        except subprocess.TimeoutExpired as error:result['exitCode']=None;result['errors'].append(repr(error))
        rows=[json.loads(line) for line in (out/'rows.jsonl').read_text().splitlines()]
        result['dropDiagnostics']=diagnose_drops(rows)
        result['summary']=validate(rows,1200 if kind=='long' else 30)
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
        result['errors'].append(repr(error))
    finally:
        if identity:
            changed=[n for n,h in {**identity['sourceHashes'],**identity['binaryHashes']}.items() if not (ROOT/n).exists() or digest(ROOT/n)!=h]
            result['identityUnchanged']=not changed
            if changed:result['errors'].append('Changed identity: '+str(changed))
        result['complete']=result.get('exitCode')==0 and not result['errors'] and bool(result.get('summary')) and result.get('identityUnchanged',False)
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('kind',choices=['short','long']);parser.add_argument('directory',type=Path)
    parser.add_argument('--short-evidence',type=Path)
    args=parser.parse_args();result=collect(args.kind,args.directory,args.short_evidence);print(json.dumps(result,indent=2));sys.exit(0 if result['complete'] else 1)
