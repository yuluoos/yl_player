#!/usr/bin/env python3
"""Bounded experimental paired-node timing gate; never a physical output oracle."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
HELPER = ROOT / 'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Audio/YlAudioCompletionGroup.swift'


def analyze(value):
    errors = []
    start, end = value['startedUs'], value['endedUs']
    if end-start < 8_000_000: errors.append('short observation')
    groups = {kind: {} for kind in ('rendered', 'reference', 'candidate')}
    for row in value['events']:
        kind, ordinal, time = row['kind'], row['ordinal'], row['rawUs']
        if kind not in groups or ordinal not in range(200) or not start <= time <= end:
            errors.append('invalid event'); continue
        if ordinal in groups[kind]: errors.append('duplicate event')
        groups[kind][ordinal] = time
    for kind, rows in groups.items():
        if set(rows) != set(range(200)): errors.append('incomplete '+kind)
    paired = sorted(groups['reference'].keys() & groups['candidate'].keys())
    diffs = [groups['candidate'][i]-groups['reference'][i] for i in paired]
    early = [i for i, delta in zip(paired, diffs) if delta < 0]
    if early: errors.append('candidate earlier than playedBack reference')
    if value['failure'] is not None or value['pendingBeforeStop'] != 0 or value['pendingAfterStop'] != 0:
        errors.append('retirement failed or incomplete')
    if not 1 <= value['peakPending'] <= 64: errors.append('invalid capacity peak')
    samples = value['samples']
    if len(samples) < 2: errors.append('missing observations')
    previous = start
    for sample in samples:
        begin, finish = sample['startedUs'], sample['endedUs']
        if not previous <= begin <= finish <= end or begin-previous > 250_000:
            errors.append('observation gap/order')
        previous = finish
        latency, ref, quantum = sample['latency'], sample['referenceLatency'], sample['quantumSeconds']
        if not all(math.isfinite(x) and x > 0 for x in (latency, ref, quantum)) or abs(latency-ref) > .000001:
            errors.append('unknown or unequal latency')
        if sample['outputSampleRate'] <= 0 or not math.isclose(quantum, sample['maximumFramesToRender']/sample['outputSampleRate']):
            errors.append('invalid quantum')
        a, b = sample['referenceSampleTime'], sample['candidateSampleTime']
        if (a is None) != (b is None) or (a is not None and abs(a-b) > 1024):
            errors.append('node clocks not paired within one input buffer')
        if sample['candidatePlaying'] != sample['referencePlaying'] or sample['failure'] is not None or not 0 <= sample['pending'] <= 64:
            errors.append('invalid paired state')
    if end-previous > 250_000: errors.append('final observation gap')
    expected = [('pause', 1_000_000), ('resume', 1_500_000), ('rate2', 2_000_000), ('rate1', 3_000_000)] if value['scenario'] == 'transport' else []
    if value['scenario'] not in ('steady', 'transport'): errors.append('unknown scenario')
    actions = value['actions']
    if [a['name'] for a in actions] != [a[0] for a in expected]: errors.append('missing transport actions')
    for action, (_, due) in zip(actions, expected):
        if not start+due <= action['startedUs'] <= action['endedUs'] <= min(start+due+250_000, end):
            errors.append('late or invalid action')
    # Require observed post-action states away from call boundaries.
    windows = [(300_000, 900_000, True, 1, True)]
    if expected:
        windows += [(1_100_000, 1_450_000, False, 1, True), (1_650_000, 1_900_000, True, 1, True),
                    (2_250_000, 2_900_000, True, 2, False), (3_250_000, 3_800_000, True, 1, True)]
    for low, high, playing, rate, bypass in windows:
        eligible = [s for s in samples if start+low <= s['startedUs'] and s['endedUs'] <= start+high]
        if not eligible or any(s['candidatePlaying'] != playing or s['rate'] != rate or s['bypass'] != bypass for s in eligible):
            errors.append('required transport state not observed')
        if playing and not any(s['referenceSampleTime'] is not None and s['candidateSampleTime'] is not None for s in eligible):
            errors.append('missing paired clocks in playing window')
    paused = []
    if len(actions) == 4:
        paused = [i for i, t in groups['candidate'].items() if actions[0]['endedUs'] <= t < actions[1]['startedUs']]
    return dict(complete=not errors, errors=sorted(set(errors)), counts={k: len(v) for k, v in groups.items()},
                earlyOrdinals=early, candidateMinusReferenceUs=dict(min=min(diffs), median=statistics.median(diffs), max=max(diffs)) if diffs else None,
                pausedCandidateOrdinals=sorted(paused), peakPending=value['peakPending'], samples=len(samples))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); out = args.output; out.mkdir(parents=True, exist_ok=False)
    sources = {'main.swift': HERE/'audio_retirement_pair.swift', 'AudioRetirementPrototype.swift': HERE/'AudioRetirementPrototype.swift', 'YlAudioCompletionGroup.swift': HELPER}
    for name, path in sources.items(): shutil.copyfile(path, out/name)
    shutil.copyfile(Path(__file__), out/'run_audio_retirement_pair.py')
    binary = out/'probe'
    command = ['xcrun', 'swiftc', '-module-cache-path', str(out/'cache'), *[str(out/k) for k in sources], '-o', str(binary)]
    built = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (out/'build.stdout').write_text(built.stdout); (out/'build.stderr').write_text(built.stderr)
    if built.returncode: raise RuntimeError('compile failed; preserved build diagnostics')
    protocol = dict(schema='audio-retirement-pair-v1', scenarios=['steady', 'transport'], buffersPerNode=200,
                    seconds=8, timeoutSeconds=25, pendingCapacity=64, evidenceMaxAgeUs=100_000,
                    noEarlyToleranceUs=0, maxObservationGapUs=250_000, maxActionDelayUs=250_000,
                    maxNodeSampleDifference=1024, pollingSeconds=.01,
                    candidateDeadline='rendered raw timestamp + ceil(outputPresentationLatency us) + ceil(maximumFramesToRender/outputSampleRate us)',
                    route='fixed injected token 1; no actual route observer', productionIntegration=False,
                    sources={k: sha(out/k) for k in sources}, binarySha256=sha(binary), collectorSha256=sha(Path(__file__)),
                    baseCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    system=subprocess.check_output(['sw_vers'], text=True), architecture=os.uname().machine)
    (out/'protocol.json').write_text(json.dumps(protocol, indent=2)+'\n')
    summaries = []
    env = {k:v for k,v in os.environ.items() if not k.startswith('Malloc')}
    for scenario in protocol['scenarios']:
        record = dict(scenario=scenario, complete=False)
        try:
            result = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=25, env=env)
            (out/(scenario+'.stdout')).write_text(result.stdout); (out/(scenario+'.stderr')).write_text(result.stderr)
            record['returncode'] = result.returncode
            rows = [x.removeprefix('YL_RETIREMENT_PROBE=') for x in result.stdout.splitlines() if x.startswith('YL_RETIREMENT_PROBE=')]
            if result.returncode or len(rows) != 1: raise RuntimeError('child failed or missing unique result')
            value = json.loads(rows[0]); (out/(scenario+'.json')).write_text(json.dumps(value, indent=2)+'\n')
            if value['scenario'] != scenario: raise RuntimeError('scenario mismatch')
            record.update(analyze(value))
        except subprocess.TimeoutExpired as error:
            (out/(scenario+'.stdout')).write_bytes(error.stdout or b'')
            (out/(scenario+'.stderr')).write_bytes(error.stderr or b'')
            record['error'] = 'owned child timeout; subprocess.run killed and reaped child'
        except Exception as error:
            record['error'] = str(error)
        summaries.append(record)
        (out/'summary.json').write_text(json.dumps(dict(complete=len(summaries)==2 and all(x['complete'] for x in summaries), runs=summaries), indent=2)+'\n')
    print((out/'summary.json').read_text())


if __name__ == '__main__': main()
