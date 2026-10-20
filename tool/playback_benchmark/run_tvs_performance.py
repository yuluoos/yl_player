#!/usr/bin/env python3
"""Source-bind existing owned TVS RTMP business acceptance and its timing spans."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse, unquote
from performance_gate import canonical, digest as object_digest, integer, require, stats
from run_public_stress import source_identity
from run_resources import ROOT, run_logged, digest

PHASES={'switchChannel','sourceAttempt','scriptResolution','sourcePreparation','kernelFirstFrame','firstFrameObserved'}


def parse_log(path):
    switches=[];receipts=[]
    for line in path.read_text().splitlines():
        for prefix, target in [('P08_SWITCH=',switches),('P05_RECEIPT ',receipts)]:
            if prefix not in line:continue
            raw=line.split(prefix,1)[1]
            require(len(raw)<256*1024)
            from summarize import unique_object,reject_constant
            target.append(json.loads(raw,object_pairs_hook=unique_object,parse_constant=reject_constant))
    require(len(receipts)==1 and 0<len(switches)<=128)
    receipt=receipts[0];run=receipt['run']
    complete=all(receipt.get(k) is True for k in ('completed','ownedCleanupCompleted','providerAsyncCleanupVerified'))
    durations={phase:[] for phase in PHASES}
    for switch in switches:
        require(switch['run']==run and switch['boundary']=='public-first-frame-future-observed')
        require(integer(switch['channelIndex'],0,11) and integer(switch['sourceAttempts']))
        require(switch['physicalOutputVerified'] is False and integer(switch['omitted']))
        spans=switch['spans'];require(isinstance(spans,list) and len(spans)<=128)
        require(switch['sourceAttempts']==sum(s['phase']=='sourceAttempt' for s in spans))
        complete &= switch['omitted']==0 and not switch.get('incomplete',False)
        for span in spans:
            require(set(span)=={'phase','startedUs','endedUs','outcome'})
            require(span['phase'] in PHASES and span['outcome'] in ('returned','failed'))
            require(integer(span['startedUs']) and integer(span['endedUs']) and span['endedUs']>=span['startedUs'])
            complete &= span['outcome']=='returned'
            durations[span['phase']].append(span['endedUs']-span['startedUs'])
        starts=[s['startedUs'] for s in spans if s['phase']=='switchChannel']
        frames=[s['endedUs'] for s in spans if s['phase']=='firstFrameObserved']
        complete &= len(starts)==1 and bool(frames) and any(s['phase']=='kernelFirstFrame' for s in spans)
        if len(starts)==1 and frames:
            require(frames[-1]>=starts[0])
            switch['businessFirstFrameUs']=frames[-1]-starts[0]
    return dict(complete=bool(complete),receipt=receipt,switches=switches,
        summary={phase:stats(values) for phase,values in durations.items()},baseline=False,physicalOutputVerified=False)


def tvs_identity(root):
    names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--',
        'lib','integration_test','assets','macos','pubspec.yaml','pubspec.lock'],cwd=root,text=True).splitlines()
    return {name:(object_digest({'symlink':str((root/name).readlink())}) if (root/name).is_symlink() else digest(root/name))
            for name in sorted(set(names)) if (root/name).is_file()}


def verify_player_dependencies(tvs, player):
    config=tvs/'.dart_tool/package_config.json';packages=json.loads(config.read_text())['packages']
    required={'yl_player','yl_player_apple','yl_player_android','yl_player_media_core','yl_player_platform_interface','yl_player_source_resolver'}
    found=set()
    for package in packages:
        if package['name'] not in required:continue
        uri=urlparse(package['rootUri']);require(uri.scheme in ('','file'))
        path=Path(unquote(uri.path))
        path=(config.parent/path).resolve() if not path.is_absolute() else path.resolve()
        require(path==(player/'packages'/package['name']).resolve());found.add(package['name'])
    require(found==required)
    return digest(config)


def collect(output,tvs,player,flutter):
    output.mkdir(parents=True,exist_ok=False)
    result=dict(schemaVersion=1,complete=False,baseline=False,releaseReady=False)
    try:
        tvs_source=tvs_identity(tvs);player_source=source_identity(player)
        config=verify_player_dependencies(tvs,player)
        result.update(tvsRoot=str(tvs),playerRoot=str(player),tvsSource=tvs_source,playerSource=player_source,
            tvsSourceHash=object_digest(tvs_source),playerSourceHash=object_digest(player_source),packageConfigHash=config,
            tvsCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=tvs,text=True).strip(),
            playerCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=player,text=True).strip(),buildMode='debug',
            architecture='arm64',cacheState='os-cache-uncontrolled')
        command=['env','FLUTTER_XCODE_ARCHS=arm64',sys.executable,str(ROOT/'tool/rtmp_acceptance/business.py'),'--',
            flutter,'test','integration_test/live_subscription_playback_test.dart','-d','macos','--no-pub']
        result['command']=command
        (output/'protocol.json').write_bytes(canonical(result))
        result['exitCode']=run_logged(command,tvs,output/'playback.log',1200)
        parsed=parse_log(output/'playback.log');result['observations']=parsed
        result['sourceUnchanged']=tvs_identity(tvs)==tvs_source and source_identity(player)==player_source and verify_player_dependencies(tvs,player)==config
        binary=tvs/'build/macos/Build/Products/Debug/tvs.app/Contents/MacOS/tvs'
        result['hostBinarySha256']=digest(binary)
        result['complete']=result['exitCode']==0 and result['sourceUnchanged'] and parsed['complete']
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError):
        result.update(complete=False,failure='collection-incomplete')
    finally:
        result['files']={p.name:dict(sha256=digest(p),bytes=p.stat().st_size) for p in output.iterdir() if p.is_file() and p.name!='result.json'}
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path);parser.add_argument('--tvs',required=True,type=Path)
    parser.add_argument('--player',required=True,type=Path);parser.add_argument('--flutter',required=True)
    args=parser.parse_args()
    passed=collect(args.output.resolve(),args.tvs.resolve(),args.player.resolve(),args.flutter)
    print('TVS source-bound phases collected.' if passed else 'TVS collection incomplete; receipt retained.')
    sys.exit(0 if passed else 1)
