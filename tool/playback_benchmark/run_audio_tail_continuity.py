"""Node-frame continuity and bounded tail-wait selection; not physical output proof."""
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
from run_audio_callback_roots import digest
from run_audio_terminal_probe import SHARED


def validate(row,scenario,pid):
    n=2000 if scenario=='steady' else 100
    if (row['scenario'],row['pid'],row['accepted'])!=(scenario,pid,n):raise ValueError('Identity/acceptance')
    if not row['drained'] or row['pending']!=0 or row['ledgerBytes']!=0 or not 0<row['ledgerPeak']<=196608:raise ValueError('Drain/ledger')
    marker=row['marker']
    if marker['frames']!=n*1024 or marker['errors']:raise ValueError('Missing/duplicate/reordered frame markers')
    if scenario=='steady' and marker['interiorZeroFrames']!=0:raise ValueError('Silent interior frames')
    expected=list(range(1,n+1));submissions=row['submissions'];events=row['events']
    if [s['ordinal'] for s in submissions]!=expected or sorted(e['ordinal'] for e in events)!=expected:raise ValueError('Missing/duplicate callbacks')
    for collection in (submissions,events):
        for s in collection:
            if s['playedBack']!=(s['ordinal']==n if scenario=='steady' else s['ordinal']>=40):raise ValueError('Wrong completion mode')
    samples=row['samples'];times=[s['rawUs'] for s in samples]
    if len(times)<2:raise ValueError('Missing poll observations')
    gaps=[b-a for a,b in zip(times,times[1:])]
    if min(gaps)<0 or max(gaps)>50000:raise ValueError('Poll cadence exceeds pre-frozen 50ms')
    for s in samples:
        if not(0<=s['pending']<=24 and 0<=s['bytes']<=196608 and 0<=s['ledgerBytes']<=196608 and 0<=s['durationUs']<=511992):raise ValueError('Sample bounds')
    delay=None
    if row['fallbackCount']!=(0 if scenario=='steady' else 1):raise ValueError('Unexpected fallback count')
    if scenario=='starve':
        actions={name:[a['rawUs'] for a in row['actions'] if a['name']==name] for name in ('starved','fallback','refill')}
        if any(len(v)!=1 for v in actions.values()):raise ValueError('Missing/duplicate fallback actions')
        delay=actions['fallback'][0]-actions['starved'][0]
        if not 100000<=delay<=100000+max(gaps) or actions['fallback'][0]>=actions['refill'][0]:raise ValueError('Tail wait not bounded by observed polling')
    return dict(buffers=n,frames=marker['frames'],interiorZeroFrames=marker['interiorZeroFrames'],
        callbacks=len(events),playedBackCallbacks=sum(s['playedBack'] for s in submissions),samples=len(samples),
        maxPollGapUs=max(gaps),tailWaitUs=delay)


def collect(output):
    source=Path(__file__).parent;output=output.resolve();output.mkdir(parents=True,exist_ok=False)
    directory=output/'sources';directory.mkdir()
    production=[SHARED/'Audio/YlAudioCompletionGroup.swift',SHARED/'FFmpeg/YlManagedBufferLedger.swift',SHARED/'FFmpeg/YlBoundedBufferPlan.swift']
    local=[source/name for name in ('audio_tail_continuity.swift','AudioTerminalBudgetPrototype.swift','audio_terminal_support.swift',
        'run_audio_tail_continuity.py','test_audio_tail_continuity.py','run_audio_terminal_probe.py','run_audio_callback_roots.py')]
    for p in production+local:(directory/p.name).write_bytes(p.read_bytes())
    main=directory/'main.swift';main.write_bytes((directory/'audio_tail_continuity.swift').read_bytes())
    binary=output/'audio_tail_continuity'
    command=['xcrun','swiftc','-O','-g','-module-cache-path',str(output/'cache'),str(main)]+[str(directory/p.name) for p in production]+[
        str(directory/'AudioTerminalBudgetPrototype.swift'),str(directory/'audio_terminal_support.swift'),'-o',str(binary)]
    with (output/'build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=log,check=True,timeout=120)
    env={k:v for k,v in os.environ.items() if not k.startswith('MallocStackLogging')}
    protocol=dict(version=1,scenarios=['steady','starve'],framesPerBuffer=1024,sampleRate=48000,
        marker='Exact Float32 (sourceFrameIndex+1)/4194304 at player tap, final mixer muted',
        steadyBuffers=2000,starveBuffers=100,starveAfter=40,producerWaitUs=300000,maxTailWaitUs=100000,
        pollTargetUs=10000,maxPollGapUs=50000,fallbackDelayLimit='100000 + largest observed adjacent poll gap',
        MallocStackLogging=False,heapPhases=['configured','observed','disposed'],
        productionAdmission=False,downstreamBoundProven=False,
        limitations=['Player-node delivery, not speaker/physical AV or production clock',
            'Fallback restores per-buffer playedBack retention; not a whole-player memory fix',
            'No heap during observed playback; marker tap and journaling still add overhead',
            'Short fixed-rate standalone graph, no longplay/real route/device/OS matrix'],
        sources={p.name:digest(p) for p in production+local},binarySha256=digest(binary),buildCommand=command)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    result=dict(complete=False,productionAdmission=False,downstreamBoundProven=False,arms=[])
    def save():(output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save()
    for scenario in protocol['scenarios']:
        folder=output/scenario;folder.mkdir();arm=dict(scenario=scenario,status='running',probes=[]);result['arms'].append(arm);save()
        with (folder/'stderr.txt').open('w') as stderr:
            proc=subprocess.Popen([str(binary),scenario],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True,env=env)
            select=selectors.DefaultSelector();select.register(proc.stdout,selectors.EVENT_READ);arm['pid']=proc.pid
            try:
                for phase in protocol['heapPhases']:
                    if not select.select(75):raise TimeoutError('Missing '+phase)
                    line=proc.stdout.readline();(folder/(phase+'.json')).write_text(line);row=json.loads(line)
                    if (row['phase'],row['scenario'],row['pid'])!=(phase,scenario,proc.pid):raise ValueError('Wrong checkpoint')
                    if phase=='observed':
                        try:arm['observation']=validate(row,scenario,proc.pid)
                        except (ValueError,KeyError,TypeError) as error:arm['observationError']=repr(error)
                    actual=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','comm='],text=True,timeout=2).strip()
                    if actual!=str(binary):raise ValueError('Owned process identity')
                    p=folder/(phase+'-heap.txt');probe=dict(phase=phase,status='pending');arm['probes'].append(probe);save()
                    with p.open('w') as stream:child=subprocess.run(['/usr/bin/heap','--noContent',str(proc.pid)],stdout=stream,stderr=stream,timeout=8)
                    raw=p.read_text();match=re.search(r'^\s*(\d+)\s+(\d+)\s+[\d.]+\s+dispatch_source_t\s',raw,re.M)
                    probe.update(status='captured' if child.returncode==0 and match and f'audio_tail_continuity [{proc.pid}]' in raw else 'failed',
                        sha256=digest(p),bytes=p.stat().st_size,dispatchSources=int(match[1]) if match else None)
                    save();proc.stdin.write('continue\n');proc.stdin.flush()
                arm['exitCode']=proc.wait(timeout=5)
                arm['status']='complete' if arm['exitCode']==0 and 'observation' in arm and all(p['status']=='captured' for p in arm['probes']) else 'failed'
            except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:arm.update(status='failed',error=repr(error))
            finally:
                if proc.poll() is None:proc.kill();proc.wait(timeout=5)
                select.close();proc.stdin.close();proc.stdout.close();arm.update(exitCode=proc.returncode,processExited=True);save()
    result['complete']=all(a['status']=='complete' for a in result['arms']);save();return result['complete']


if __name__=='__main__':sys.exit(0 if collect(Path(sys.argv[1])) else 1)
