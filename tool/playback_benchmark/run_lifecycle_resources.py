"""Fixed R2 lifecycle observation; never a whole-process memory-bound proof."""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
from run_audio_integration_resources import ROOT, capture_heap, digest, freeze

PHASES = ['baseline','cycle1','cycle3','cycle6','disposed']
ROW_PHASES = ['baseline']+[f'cycle{n}' for n in range(1,7)]+['disposed','disposedLater']


def validate_rows(rows, candidate, kind):
    def require(ok, message):
        if not ok: raise ValueError(message)
    require(kind in ('seek','load-close'), 'Wrong lifecycle kind')
    require([r['phase'] for r in rows]==ROW_PHASES, 'Missing or duplicate rows')
    require(len({r['pid'] for r in rows})==1, 'PID changed')
    require(all(math.isfinite(r['uptime']) for r in rows) and all(b['uptime']>a['uptime'] for a,b in zip(rows,rows[1:])), 'Invalid row times')
    for i,r in enumerate(rows):
        cycle=min(i,6);active=kind=='seek' and 1<=i<=6
        require(r['candidate']==candidate and r['kind']==kind and r['rounds']==6 and r['cycle']==cycle,'Wrong profile/cycle')
        require(not r['nativePlaying'] and not r['pending'] and r['ownedBytes']==0 and not r['failures'] and not r['retries'],'Playback not safely drained')
        require(r['completed']==cycle and r['sessions']==((1 if cycle else 0) if kind=='seek' else cycle) and r['firstFrames']==r['sessions'],'Wrong event/session counts')
        require(r['activeGraph']==active and r['engineRunning']==active and (r['attachedNodes']==4 if active else r['attachedNodes']==0),'Wrong graph state')
        require(not r['retiredEntryAlive'] and r['ledgerBytes']>=0 and (active or r['ledgerBytes']==0),'Retired owner/budget remains')
        require(r['submissionAnchor']==(active and candidate),'Candidate fallback/wrong anchor')
        require(r['callbackObservation']=='unobserved' and r['playedCallbacks'] is None and r['renderedCallbacks'] is None,'Fabricated callback observation')
        if cycle==0:require(r['playedSubmissions']==r['renderedSubmissions']==r['videoFrames']==0,'Nonempty baseline')
        elif candidate:require(r['playedSubmissions']==cycle and r['renderedSubmissions']>cycle,'Wrong candidate modes')
        else:require(r['playedSubmissions']>cycle and r['renderedSubmissions']==0,'Wrong legacy modes')
        if 1<=i<=6:
            prev=rows[i-1]
            require(r['videoFrames']>prev['videoFrames'],'No new video frames')
            require(r['playedSubmissions']-prev['playedSubmissions']==1 if candidate else r['playedSubmissions']-prev['playedSubmissions']>1,'Missing played submissions')
            if candidate:require(r['renderedSubmissions']-prev['renderedSubmissions']>1,'Missing rendered submissions')
        if i>=7:
            require(all(r[k]==rows[6][k] for k in ('completed','sessions','firstFrames','playedSubmissions','renderedSubmissions','videoFrames','failures')),'Events changed after disposal')
    require(all(b['publications']>=a['publications'] for a,b in zip(rows,rows[1:])) and rows[-1]['publications']==rows[-2]['publications'], 'Late post-disposal publication')
    require(rows[-1]['uptime']-rows[-2]['uptime']>=2,'Missing delayed disposal observation')
    return dict(cycles=6,playedSubmissions=rows[-1]['playedSubmissions'],renderedSubmissions=rows[-1]['renderedSubmissions'],videoFrames=rows[-1]['videoFrames'],productionAdmission=False,downstreamBoundProven=False)


def collect(arm, kind, directory):
    if arm not in ('legacy','candidate') or kind not in ('seek','load-close'):raise ValueError('Wrong profile')
    out=Path(directory).resolve();out.mkdir(parents=True,exist_ok=False)
    products=ROOT/'packages/yl_player/example/build/native-macos-tests/Build/Products'
    extras=[ROOT/'tool/playback_benchmark'/n for n in ('run_lifecycle_resources.py','test_lifecycle_resources.py','summarize_lifecycle_resources.py','decoded-lifecycle-resources-protocol.md')]
    identity=freeze(out,products,extras)
    manifests=list(products.glob('*.xctestrun'))
    if len(manifests)!=1:raise ValueError('Expected one test manifest')
    def absolute(v):
        if isinstance(v,str):return v.replace('__TESTROOT__',str(products))
        if isinstance(v,list):return [absolute(x) for x in v]
        if isinstance(v,dict):return {k:absolute(x) for k,x in v.items()}
        return v
    config=absolute(plistlib.loads(manifests[0].read_bytes()));target=config['RunnerTests']
    for env in (os.environ,target.get('EnvironmentVariables',{}),target.get('TestingEnvironmentVariables',{})):
        if any(k.startswith('MallocStackLogging') for k in env):raise ValueError('MSL forbidden')
    target.setdefault('EnvironmentVariables',{}).update(YL_AUDIO_PROBE_DIRECTORY=str(out),YL_AUDIO_PROBE_ARM=arm,YL_AUDIO_LIFECYCLE_KIND=kind)
    manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
    command=[sys.executable,'-B',str(ROOT/'tool/run_with_display_awake.py'),'xcodebuild','test-without-building','-quiet','-xctestrun',str(manifest),'-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO','-only-testing:RunnerTests/YlMacosAudioTests/testActualDecodedRepeatedLifecycleResources','-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','180','-default-test-execution-time-allowance','180','-resultBundlePath',str(out)+'.xcresult']
    (out/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    result=dict(complete=False,arm=arm,kind=kind,rounds=6,probes=[],errors=[],productionAdmission=False,downstreamBoundProven=False)
    def save():(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save();offset=0;seen=set();started=time.monotonic()
    with (out/'xcode.log').open('w') as log:
        proc=subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            while proc.poll() is None:
                if time.monotonic()-started>240:raise TimeoutError('Owned command exceeded240s')
                file=out/'rows.jsonl'
                if file.exists():
                    for line in file.read_text().splitlines()[offset:]:
                        try:row=json.loads(line)
                        except json.JSONDecodeError:break
                        offset+=1;phase=row['phase']
                        if phase not in PHASES or phase in seen:continue
                        seen.add(phase);entry=dict(phase=phase,pid=row['pid'],valid=False)
                        try:
                            actual=subprocess.check_output(['/bin/ps','-p',str(row['pid']),'-o','comm='],text=True,timeout=2).strip()
                            if actual!=str(products/'Debug/yl_player_example.app/Contents/MacOS/yl_player_example'):raise ValueError('Unexpected process')
                            if row['nativePlaying'] or row['pending'] or row['ownedBytes'] or row['failures']:raise ValueError('Unsafe live heap request')
                            if phase!='baseline' and row['completed']!=row['cycle']:raise ValueError('Not completed')
                            entry.update(capture_heap(row['pid'],out/(phase+'-heap.txt')))
                        except (OSError,ValueError,subprocess.SubprocessError) as error:entry['error']=repr(error)
                        finally:result['probes'].append(entry);save();(out/(phase+'.ack')).touch()
                        print(arm,kind,phase,entry['valid'],flush=True)
                time.sleep(.05)
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:result['errors'].append(repr(error))
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
            result['testExitCode']=proc.returncode
            try:
                result['observation']=validate_rows([json.loads(x) for x in (out/'rows.jsonl').read_text().splitlines()],arm=='candidate',kind)
                for name,h in {**identity['sourceHashes'],**identity['binaryHashes']}.items():
                    if digest(ROOT/name)!=h:raise ValueError('Source/binary changed: '+name)
            except (OSError,ValueError,KeyError,TypeError) as error:result['errors'].append(repr(error))
            result['complete']=proc.returncode==0 and not result['errors'] and [p['phase'] for p in result['probes']]==PHASES and all(p['valid'] for p in result['probes'])
            save()
    return result['complete']


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('arm',choices=['legacy','candidate']);p.add_argument('kind',choices=['seek','load-close']);p.add_argument('directory',type=Path)
    a=p.parse_args();sys.exit(0 if collect(a.arm,a.kind,a.directory) else 1)
