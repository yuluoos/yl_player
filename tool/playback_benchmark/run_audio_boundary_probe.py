"""Bounded tail experiment. Captures failures; neither physical nor production admission."""
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
from run_audio_callback_roots import digest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Audio/YlAudioCompletionGroup.swift'
SCENARIOS = ('single', 'pausedEOF', 'grouped', 'reference')
PHASES = ('configured', 'observed', 'disposed')


def validate_observation(row, scenario, pid):
    target = 1 if scenario == 'single' else 3 if scenario == 'pausedEOF' else 200
    group = 1 if scenario == 'reference' else 8
    if (row['phase'], row['scenario'], row['pid'], row['target'], row['groupSize']) != ('observed', scenario, pid, target, group):
        raise ValueError('Observation identity mismatch')
    submissions, events, samples = row['submissions'], row['events'], row['samples']
    expected = list(range(1, target+1))
    if [s['ordinal'] for s in submissions] != expected or sorted(e['ordinal'] for e in events) != expected:
        raise ValueError('Missing or duplicate buffers/notifications')
    fences = [i for i in expected if i % group == 0 or i == target]
    if ([s['ordinal'] for s in submissions if s['boundary']] != fences or
            sorted(e['ordinal'] for e in events if e['boundary']) != fences or
            any(s['frames'] != 1024 for s in submissions) or any(e['generation'] != 1 for e in events)):
        raise ValueError('Wrong real tail boundary')
    if any((e['boundary'] != submissions[e['ordinal']-1]['boundary'] or
            e['rawUs'] < submissions[e['ordinal']-1]['rawUs']) for e in events):
        raise ValueError('Invalid callback provenance/time')
    if (row['accepted'], row['pending'], row['pendingBytes'], row['pendingDurationUs'], row['drained'], row['alivePCM']) != (target, 0, 0, 0, True, 0):
        raise ValueError('Incomplete drain or retained PCM')
    if not samples or not 1 <= row['peakCount'] <= 24 or any(not (0 <= s['pending'] <= 24 and
            0 <= s['bytes'] <= 24*8192 and 0 <= s['durationUs'] <= 24*21333) for s in samples):
        raise ValueError('Admission bounds violated')
    eof_events = [a for a in row['actions'] if a['name'] == 'EOF']
    if len(eof_events) != 1 or not samples[-1]['drained'] or eof_events[0]['rawUs'] > samples[-1]['rawUs']:
        raise ValueError('Missing EOF or observed final drain')
    last_fence = max(e['rawUs'] for e in events if e['boundary'])
    if any(s['drained'] and s['rawUs'] < last_fence for s in samples):
        raise ValueError('Drained before real tail notification')
    if scenario == 'pausedEOF':
        eof = [a for a in row['actions'] if a['name'] == 'EOF']
        resume = [a for a in row['actions'] if a['name'] == 'play']
        paused = [s for s in samples if not s['playing']]
        if len(eof) != 1 or eof[0]['playing'] or len(resume) != 1 or not paused or any(s['drained'] for s in paused):
            raise ValueError('Paused EOF not exercised')
        if eof[0]['rawUs'] >= resume[0]['rawUs'] or any(e['rawUs'] < resume[0]['rawUs'] for e in events):
            raise ValueError('Unexpected notification before resume')
    return dict(buffers=target, fences=len(fences), ordinary=target-len(fences), peakCount=row['peakCount'])


def collect(output):
    output = output.resolve(); output.mkdir(parents=True, exist_ok=False)
    source_dir = output/'sources'; source_dir.mkdir()
    sources = [Path(__file__).resolve(), Path(__file__).with_name('audio_boundary_probe.swift'),
        Path(__file__).with_name('AudioBoundaryPrototype.swift'), Path(__file__).with_name('test_audio_boundary_probe.py'),
        Path(__file__).with_name('run_audio_callback_roots.py'), HELPER]
    for source in sources: (source_dir/source.name).write_bytes(source.read_bytes())
    main = source_dir/'main.swift'; main.write_bytes((source_dir/'audio_boundary_probe.swift').read_bytes())
    binary = output/'audio_boundary_probe'
    command = ['xcrun','swiftc','-g','-module-cache-path',str(output/'cache'),str(main),
        str(source_dir/'AudioBoundaryPrototype.swift'),str(source_dir/HELPER.name),'-o',str(binary)]
    with (output/'build.log').open('w') as log:
        subprocess.run(command,stdout=log,stderr=log,check=True,timeout=120)
    protocol = dict(version=1, scenarios=SCENARIOS, phases=PHASES, frames=1024, sampleRate=48000,
        channels=2, groupSize=8, maxCount=24, maxBytes=196608, maxDurationUs=511992,
        durationsSeconds=dict(single=1.5,pausedEOF=1.5,grouped=7,reference=7),
        environment={'MallocStackLogging':'full','MallocStackLoggingNoCompact':'1'},
        admission='Exact submissions/events/tails, zero pending and PCM, no early logical drain, bounded reservations, paused EOF exercised',
        productionAdmission=False, retentionGate='Any continued system timer retention prohibits bounded-memory claims',
        limitations=['Silent standalone graph, not renderer/ledger integration or physical sound',
            'No continuity, route/rate/seek, iOS, lowest OS or long-play qualification',
            'Heap only outside playback; MSL remains on; no cross-arm performance subtraction'],
        sources={s.name:digest(s) for s in sources}, binarySha256=digest(binary), buildCommand=command)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    result = dict(complete=False, productionAdmission=False, arms=[])
    def save(): (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save()
    for scenario in SCENARIOS:
        folder = output/scenario; folder.mkdir()
        arm = dict(scenario=scenario,status='running',probes=[]);result['arms'].append(arm); save()
        with (folder/'stderr.txt').open('w') as stderr:
            proc = subprocess.Popen([str(binary),scenario],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,
                text=True,env=dict(os.environ,**protocol['environment']))
            selector = selectors.DefaultSelector(); selector.register(proc.stdout,selectors.EVENT_READ)
            arm['pid']=proc.pid
            try:
                for phase in PHASES:
                    if not selector.select(20): raise TimeoutError('Missing checkpoint '+phase)
                    line=proc.stdout.readline(); (folder/(phase+'.json')).write_text(line);row=json.loads(line)
                    if (row['pid'],row['scenario'],row['phase']) != (proc.pid,scenario,phase): raise ValueError('Wrong checkpoint')
                    if phase=='observed':
                        try: arm['observation']=validate_observation(row,scenario,proc.pid)
                        except (ValueError,KeyError,TypeError) as error: arm['observationError']=repr(error)
                    actual=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','comm='],text=True,timeout=2).strip()
                    if actual != str(binary): raise ValueError('Owned executable mismatch')
                    probe = dict(phase=phase,status='pending'); arm['probes'].append(probe);save()
                    path=folder/(phase+'-heap.txt')
                    with path.open('w') as log:
                        child=subprocess.run(['/usr/bin/heap','--noContent',str(proc.pid)],stdout=log,stderr=log,timeout=8)
                    raw=path.read_text()
                    match=re.search(r'^\s*(\d+)\s+(\d+)\s+[\d.]+\s+dispatch_source_t\s',raw,re.M)
                    identity=f'audio_boundary_probe [{proc.pid}]' in raw
                    probe.update(status='captured' if child.returncode==0 and match and identity else 'failed',
                        exitCode=child.returncode,sha256=digest(path),bytes=path.stat().st_size,
                        dispatchSources=int(match[1]) if match else None)
                    save();proc.stdin.write('continue\n');proc.stdin.flush()
                arm['exitCode']=proc.wait(timeout=5)
                arm['status']='complete' if arm['exitCode']==0 and 'observation' in arm and all(p['status']=='captured' for p in arm['probes']) else 'failed'
            except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
                arm.update(status='failed',error=repr(error))
            finally:
                if proc.poll() is None: proc.kill();proc.wait(timeout=5)
                selector.close();proc.stdin.close();proc.stdout.close()
                arm.update(exitCode=proc.returncode,processExited=True);save()
    result['complete']=all(a['status']=='complete' for a in result['arms']);save()
    return result['complete']


if __name__ == '__main__': sys.exit(0 if collect(Path(sys.argv[1])) else 1)
