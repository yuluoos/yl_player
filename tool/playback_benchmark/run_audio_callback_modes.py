"""Compare native callback boundaries; no callback is assumed to mean audibility."""
import bisect
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
from run_audio_callback_roots import digest, raw_us

MODES = {'consumed': 0, 'rendered': 1, 'playedBack': 2}
PHASES = ('configured', 'observed', 'disposed')
OBSERVERS = ('heap', 'dispatch-stacks')
SCHEDULE = [('pause', 1000000), ('resume', 1500000), ('rate2', 2000000), ('rate1', 3000000)]
ROOT = Path(__file__).resolve().parents[2]
GROUP = ROOT / 'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Audio/YlAudioCompletionGroup.swift'


def planned_arms():
    return [dict(mode=mode, scenario=scenario, status='not_observed', probes=[
        dict(phase=phase, tool=tool, status='not_observed')
        for phase in PHASES for tool in OBSERVERS])
        for scenario in ('steady', 'transport') for mode in MODES]


def integer(value):
    return type(value) is int and value >= 0


def validate_observation(row, pid, mode, scenario):
    if (row.get('pid'), row.get('mode'), row.get('scenario'), row.get('phase')) != (pid, mode, scenario, 'observed'):
        raise ValueError('Observation identity mismatch')
    begin, end, capture = row['startedUs'], row['endedUs'], row['captureStartUs']
    if not all(integer(x) for x in (begin, end, capture)) or not capture <= begin <= end-8000000:
        raise ValueError('Incomplete eight-second observation')
    events = row['events']
    if len(events) != 200 or sorted(e['ordinal'] for e in events) != list(range(200)):
        raise ValueError('Missing or duplicate callback')
    if any(type(e['ordinal']) is not int or e['callbackType'] != MODES[mode] or
           not integer(e['rawUs']) or not capture <= e['rawUs'] <= end for e in events):
        raise ValueError('Invalid callback type or timestamp')
    if row['alive'] != 0:
        raise ValueError('Completed payload still retained')
    samples = row['samples']
    if len(samples) < 2:
        raise ValueError('Missing player clock observations')
    previous = begin
    for sample in samples:
        a, b = sample['startedUs'], sample['endedUs']
        if not all(integer(x) for x in (a,b)) or not previous <= a <= b <= end or a-previous > 250000:
            raise ValueError('Invalid sample ordering or gap')
        previous = b
        for key in ('presentationLatency', 'outputLatency', 'rate'):
            value = sample[key]
            if type(value) not in (int,float) or not math.isfinite(value) or value < 0:
                raise ValueError('Invalid latency or rate')
        if sample['sampleTime'] is not None and (type(sample['sampleTime']) is not int or
                type(sample['sampleRate']) not in (int,float) or not math.isfinite(sample['sampleRate']) or sample['sampleRate'] <= 0):
            raise ValueError('Invalid player sample time')
    if end-previous > 250000:
        raise ValueError('Missing final observation')
    expected = SCHEDULE if scenario == 'transport' else []
    actions = row['actions']
    if [a['name'] for a in actions] != [name for name,_ in expected]:
        raise ValueError('Missing transport actions')
    previous = begin
    states = [(False,1,True),(True,1,True),(True,2,False),(True,1,True)]
    for i,(action,(_,offset)) in enumerate(zip(actions,expected)):
        a,b = action['startedUs'],action['endedUs']
        if not all(integer(x) for x in (a,b)) or not previous <= a <= b <= end or not 0 <= a-begin-offset <= 250000:
            raise ValueError('Late or reordered transport action')
        previous = b
        next_start = actions[i+1]['startedUs'] if i+1 < len(actions) else end
        if not any((s['playing'],s['rate'],s['bypass']) == states[i] for s in samples if b <= s['startedUs'] < next_start):
            raise ValueError('Transport state not observed')


def callback_brackets(row):
    """Keep raw sample intervals; never interpolate across a transport change."""
    samples = row['samples']
    starts = [s['startedUs'] for s in samples]
    ends = [s['endedUs'] for s in samples]
    result = []
    for event in row['events']:
        item = dict(event, status='unbracketed')
        left = bisect.bisect_right(ends, event['rawUs'])-1
        right = bisect.bisect_left(starts, event['rawUs'])
        if left >= 0 and right < len(samples):
            a,b = samples[left],samples[right]
            item['sampleIndices'] = [left,right]
            if any(a['startedUs'] <= x['endedUs'] and x['startedUs'] <= b['endedUs'] for x in row['actions']):
                item['status'] = 'transport_crossing'
            elif a['sampleTime'] is not None and b['sampleTime'] is not None:
                if (a['sampleRate'],a['rate'],a['playing']) != (b['sampleRate'],b['rate'],b['playing']) or a['sampleTime'] > b['sampleTime']:
                    item['status'] = 'clock_transition'
                else:
                    item.update(status='bracketed', sampleRange=[a['sampleTime'],b['sampleTime']],
                        endFrameOffsets=[a['sampleTime']-(event['ordinal']+1)*1024,
                                         b['sampleTime']-(event['ordinal']+1)*1024])
        result.append(item)
    return result


def run_arm(arm, output, binary, environment):
    output.mkdir()
    def save():
        (output/'result.json').write_text(json.dumps(arm,indent=2)+'\n')
    save()
    with (output/'stderr.txt').open('w') as stderr:
        process = subprocess.Popen([str(binary),arm['mode'],arm['scenario']],stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=stderr,text=True,env=dict(os.environ,**environment))
        selector = selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
        arm.update(pid=process.pid, startedUs=raw_us(), status='running')
        try:
            for phase in PHASES:
                if not selector.select(20): raise TimeoutError('Missing checkpoint '+phase)
                line = process.stdout.readline()
                (output/(phase+'.json')).write_text(line)
                row = json.loads(line)
                if (row.get('pid'),row.get('mode'),row.get('scenario'),row.get('phase')) != (process.pid,arm['mode'],arm['scenario'],phase):
                    raise ValueError('Checkpoint identity mismatch')
                if phase == 'observed':
                    try:
                        validate_observation(row,process.pid,arm['mode'],arm['scenario'])
                        arm['observationValid'] = True
                        (output/'brackets.json').write_text(json.dumps(callback_brackets(row),indent=2)+'\n')
                    except (ValueError,KeyError,TypeError) as error:
                        arm.update(observationValid=False, observationError=str(error))
                for probe in (p for p in arm['probes'] if p['phase'] == phase):
                    actual = subprocess.check_output(['/bin/ps','-p',str(process.pid),'-o','comm='],text=True,timeout=2).strip()
                    if actual != str(binary): raise ValueError('Owned executable mismatch')
                    command = ['/usr/bin/heap','--noContent',str(process.pid)] if probe['tool']=='heap' else [
                        '/usr/bin/malloc_history',str(process.pid),'-callTree','-noContent','-invert','-ignoreThreads','dispatch_source_t']
                    probe.update(startedUs=raw_us(),command=command)
                    path = output/(phase+'-'+probe['tool']+'.txt')
                    try:
                        with path.open('w') as stream:
                            child = subprocess.run(command,stdout=stream,stderr=stream,timeout=8)
                        text = path.read_text()
                        identity = re.search(r'^Process: +audio_callback_modes \['+str(process.pid)+r'\] *$',text,re.M)
                        data = bool(re.search(r'^\s*\d+\s+',text.split('Call graph:',1)[-1].split('Binary Images:',1)[0],re.M))
                        probe.update(exitCode=child.returncode,status='captured' if child.returncode==0 and identity and data else 'failed')
                    except subprocess.TimeoutExpired: probe['status']='timeout'
                    finally:
                        probe.update(endedUs=raw_us(),raw=dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size))
                        save()
                process.stdin.write('continue\n');process.stdin.flush()
            arm['exitCode']=process.wait(timeout=5)
            arm['status']='complete' if arm.get('observationValid') and arm['exitCode']==0 and all(p['status']=='captured' for p in arm['probes']) else 'failed'
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
            arm.update(status='failed',error=repr(error))
        finally:
            if process.poll() is None: process.kill();process.wait(timeout=5)
            selector.close();process.stdin.close();process.stdout.close()
            arm.update(endedUs=raw_us(),exitCode=process.returncode,processExited=True);save()


def collect(output):
    output=output.resolve();output.mkdir(parents=True,exist_ok=False)
    sources=[Path(__file__).resolve(),Path(__file__).with_name('audio_callback_modes.swift'),
             Path(__file__).with_name('test_audio_callback_modes.py'),Path(__file__).with_name('run_audio_callback_roots.py'),GROUP]
    source_dir=output/'sources';source_dir.mkdir()
    for source in sources: (source_dir/source.name).write_bytes(source.read_bytes())
    # Multiple-source Swift executable requires its top-level source to be main.swift.
    main=source_dir/'main.swift';main.write_bytes((source_dir/'audio_callback_modes.swift').read_bytes())
    binary=output/'audio_callback_modes'
    command=['xcrun','swiftc','-g','-module-cache-path',str(output/'module-cache'),str(main),str(source_dir/GROUP.name),'-o',str(binary)]
    with (output/'build.log').open('w') as stream: subprocess.run(command,stdout=stream,stderr=stream,check=True,timeout=120)
    environment=dict(MallocStackLogging='full',MallocStackLoggingNoCompact='1')
    result=dict(arms=planned_arms(),complete=False)
    protocol=dict(version=1,purpose='callback semantics and retention comparison, not physical audibility',
        modes=MODES,scenarios=['steady','transport'],order=[(a['mode'],a['scenario']) for a in result['arms']],
        framesPerBuffer=1024,buffers=200,sampleRate=48000,channels=2,interleaved=False,
        observationSeconds=8,sampleTargetSeconds=0.01,maxSampleGapSeconds=0.25,
        transportSchedule=SCHEDULE,actionStartToleranceSeconds=0.25,
        rateBypassPolicy='rate 1 bypass=true; rate 2 bypass=false',phases=PHASES,observers=OBSERVERS,
        plannedProbes=36,environment=environment,probeTimeoutSeconds=8,checkpointTimeoutSeconds=20,
        sources={s.name:digest(s) for s in sources},binarySha256=digest(binary),buildCommand=command,
        limitations=['Fixed-order independent instrumented processes; no cross-arm performance subtraction',
            'No live heap probes within eight-second observation; MSL and sampling overhead remain',
            'Player sample time and reported latency do not measure audible output',
            'No simulated device-latency change; only current route observed',
            'Standalone graph and real production completion helper, not full renderer/Flutter'])
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    result['protocolSha256']=digest(output/'protocol.json')
    for arm in result['arms']:
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        run_arm(arm,output/(arm['scenario']+'-'+arm['mode']),binary,environment)
    result['complete']=all(a['status']=='complete' for a in result['arms'])
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


if __name__=='__main__': sys.exit(0 if collect(Path(sys.argv[1])) else 1)
