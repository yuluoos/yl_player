"""Freeze a fresh single-session protocol, retain every streamed observation."""
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from continuous import PROTOCOL, summarize_continuous
from run_resources import ROOT, EXAMPLE, HERE, digest, run_logged
from summarize import unique_object, reject_constant


def collect(output,flutter,*,memory_diagnostics=False):
    protocol=dict(PROTOCOL)
    if memory_diagnostics:
        from run_continuous_memory import diagnostic_protocol
        protocol=diagnostic_protocol()
    if any(k.startswith('MallocStackLogging') for k in os.environ):raise ValueError('Inherited stack logging must be absent')
    output.mkdir(parents=True,exist_ok=False)
    run='macos-continuous-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    result=dict(schemaVersion=1,runId=run,stage='setup',complete=False,protocol=protocol,
        performanceBaseline=False,budgetAdmission=False,physicalOutput='not_verified',leakVerdict=None)
    try:
        files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--','packages','tool/playback_benchmark'],cwd=ROOT,text=True).splitlines()
        source={n:digest(ROOT/n) for n in sorted(set(files)) if Path(n).suffix in ('.dart','.swift','.m','.h','.kt','.py','.sh','.pbxproj','.xcconfig','.podspec','.plist','.entitlements','.yaml','.lock') or Path(n).name=='Podfile'}
        result.update(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            sourceFingerprints=source,sourceHash=hashlib.sha256(json.dumps(source,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
            dependencies={n:digest(ROOT/n) for n in ['pubspec.yaml','pubspec.lock','packages/yl_player/example/pubspec.yaml','packages/yl_player/example/macos/Podfile.lock']},
            artifactFingerprints={n:digest(ROOT/n) for n in ['packages/yl_player_media_core/tool/apple_ffmpeg/bridge-artifact.lock','packages/yl_player_media_core/darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge']})
        media=EXAMPLE/'assets/test_media/format_matrix/continuous-avc-aac.mkv'
        result['mediaSha256']=digest(media)
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(media)],text=True,timeout=20))
        if not 1259<=float(probe['format']['duration'])<=1261 or [s['codec_name'] for s in probe['streams']]!=['h264','aac']:raise ValueError('Invalid continuous fixture')
        result['mediaProbe']=probe
        result['device']={k:subprocess.check_output(cmd,text=True).strip() for k,cmd in dict(model=['sysctl','-n','hw.model'],cpu=['sysctl','-n','machdep.cpu.brand_string'],os=['sw_vers','-productVersion'],osBuild=['sw_vers','-buildVersion']).items()}
        arch=subprocess.check_output(['uname','-m'],text=True).strip()
        if arch not in ('arm64','x86_64'):raise ValueError('Unsupported architecture')
        result.update(architecture=arch,buildMode='profile')
        library=output/'resources.dylib'
        with (output/'sampler-build.log').open('w') as log:
            subprocess.run(['sh',str(HERE/'build_apple_resources.sh'),str(library)],stdout=log,stderr=log,timeout=60,check=True)
        result['samplerSha256']=digest(library)
        defines=output/'defines.json'
        defines.write_text(json.dumps(dict(YL_RESOURCE_RUN_ID=run,YL_RESOURCE_LIBRARY_BYTES=base64.b64encode(library.read_bytes()).decode()))+'\n')
        result['definesSha256']=digest(defines)
        command=['/usr/bin/caffeinate','-d','-i','-u','-t','1500','env','FLUTTER_XCODE_ARCHS='+arch,flutter,'drive','-d','macos','--profile','--no-pub',
            '--driver=test_driver/integration_test.dart','--target=integration_test/continuous_benchmark_test.dart','--dart-define-from-file='+str(defines)]
        result.update(command=command,stage='playback')
        (output/'protocol.json').write_text(json.dumps(result,indent=2)+'\n')
        result['protocolSha256']=digest(output/'protocol.json')
        started=time.monotonic()
        try:result['flutterExitCode']=run_logged(command,EXAMPLE,output/'playback.log',1500)
        except subprocess.TimeoutExpired:result.update(flutterExitCode=None,commandFailure='timeout')
        result['commandElapsedSeconds']=time.monotonic()-started
        # Raw log is the authoritative retained prefix even on malformed rows.
        rows=[]
        for line in (output/'playback.log').read_text().splitlines():
            if 'YL_CONTINUOUS=' not in line:continue
            raw=line.split('YL_CONTINUOUS=',1)[1]
            if len(raw)>8192:raise ValueError('Oversized continuous record')
            rows.append(json.loads(raw,object_pairs_hook=unique_object,parse_constant=reject_constant))
            if len(rows)>247:raise ValueError('Excess continuous records')
        (output/'observations.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in rows))
        result['summary']=summarize_continuous(rows,run)
        result['sourceIdentityVerified']=all(digest(ROOT/p)==v for p,v in source.items()) and digest(media)==result['mediaSha256'] and all(digest(ROOT/p)==v for p,v in result['dependencies'].items()) and all(digest(ROOT/p)==v for p,v in result['artifactFingerprints'].items())
        executable=EXAMPLE/'build/macos/Build/Products/Profile/yl_player_example.app/Contents/MacOS/yl_player_example'
        result['appSha256']=digest(executable)
        result.update(complete=result['flutterExitCode']==0 and result['summary']['complete'] and result['sourceIdentityVerified'],stage='complete')
    except (OSError,ValueError,TypeError,KeyError,subprocess.SubprocessError) as e:
        result['errorType']=type(e).__name__
    finally:
        result['files']={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in output.iterdir() if p.is_file() and p.name!='result.json'}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']

if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: run_continuous.py NEW_DIRECTORY FLUTTER_EXECUTABLE')
    ok=collect(Path(sys.argv[1]).resolve(),sys.argv[2])
    print('Continuous observation complete; not a baseline.' if ok else 'Continuous observation incomplete; raw evidence retained.')
    raise SystemExit(0 if ok else 2)
