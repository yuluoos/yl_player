#!/usr/bin/env python3
"""Validate public live mode observations against a same-run local relay trace."""
import argparse
import json
from pathlib import Path
import re
from summarize_capture import number, require


def summarize(result, samples, receipt, connections, *, exit_code):
    require(isinstance(result, dict) and result.get('schemaVersion') == 2)
    require(isinstance(receipt, dict) and receipt.get('schemaVersion') == 1)
    require(type(exit_code) is int)
    require(result.get('protocol') in ('hls', 'flv', 'rtmp'))
    require(isinstance(result.get('runId'), str) and
            re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', result['runId']))
    for key in ('declaredMediaHash', 'profileHash'):
        require(isinstance(result.get(key), str) and re.fullmatch(r'[a-f0-9]{64}', result[key]))
    require(isinstance(result.get('profileId'), str) and
            re.fullmatch(r'[a-z0-9-]{1,80}-v[1-9][0-9]*', result['profileId']))
    identity = ('runId', 'protocol', 'declaredMediaHash', 'profileId', 'profileHash')
    require(all(receipt.get(k) == result[k] for k in identity))
    require(result.get('outcome') in ('completed', 'failed', 'timeout'))
    for key in ('cleaned', 'rapidSwitchVerified', 'staleStopVerified'):
        require(type(result.get(key)) is bool)
    require(result.get('endToEndLatencyUs') is None and result.get('evidence') == 'public-state-only')
    require(isinstance(samples, list) and len(samples) <= 1024 and
            type(result.get('sampleCount')) is int and result['sampleCount'] == len(samples))
    require(result.get('sessionId') is None or (isinstance(result['sessionId'], str) and
            0 < len(result['sessionId']) <= 200))
    scenario = result.get('scenario', 'switch')
    require(scenario in ('switch', 'baseline'))
    baseline_mode = result.get('baselineMode')
    require(scenario != 'baseline' or baseline_mode in ('smoothPlayback', 'lowLatency'))
    violations = set()
    previous = -1
    revision = -1
    for sample in samples:
        require(isinstance(sample, dict) and sample.get('runId') == result['runId'] and
                sample.get('sessionId') == result['sessionId'] and result['sessionId'] is not None)
        require(number(sample.get('elapsedUs')) and sample['elapsedUs'] >= previous and
                type(sample.get('revision')) is int and sample['revision'] >= revision)
        previous, revision = sample['elapsedUs'], sample['revision']
        require(number(sample.get('positionUs')) and type(sample.get('failed')) is bool)
        require(sample.get('mode') in (None, 'smoothPlayback', 'lowLatency'))
        require(isinstance(sample.get('stage'), str) and isinstance(sample.get('status'), str))
        require(sample.get('endToEndLatencyUs') is None)
        for key in ('mediaClockUs', 'liveOffsetUs', 'managedBufferedUs', 'rebufferCount',
                    'rebufferUs', 'reconnectCount'):
            require(key in sample and (sample[key] is None or number(sample[key])))
        if sample['failed']:
            violations.add('session_failed')
    groups = ([('baseline', baseline_mode)] if scenario == 'baseline' else
              [('smooth', 'smoothPlayback'), ('low', 'lowLatency'), ('smooth-again', 'smoothPlayback')])
    for stage, mode in groups:
        group = [s for s in samples if s['stage'] == stage]
        if not group or any(s['mode'] != mode for s in group):
            violations.add(stage+'_mode_mismatch')
        clocks = [s['mediaClockUs'] if s['mediaClockUs'] is not None else s['positionUs'] for s in group]
        # Reconnection can reset the item's clock within the same public session.
        # Require progression in the final uninterrupted playing epoch, matching
        # the device collector; a reset or buffering clock alone cannot pass.
        advancing = False
        for index in range(1, len(group)):
            if (group[index-1]['status'] != 'playing' or
                    group[index]['status'] != 'playing' or
                    clocks[index] < clocks[index-1]):
                advancing = False
            elif clocks[index] > clocks[index-1]:
                advancing = True
        if not advancing:
            violations.add(stage+'_clock_not_advancing')
    if scenario == 'baseline':
        baseline_samples = [s for s in samples if s['stage'] == 'baseline']
        if (len(baseline_samples) != len(samples) or len(baseline_samples) < 2 or
                baseline_samples[-1]['elapsedUs']-baseline_samples[0]['elapsedUs'] < 35000000):
            violations.add('baseline_window_incomplete')
    else:
        paused = [s for s in samples if s['stage'] == 'paused-low']
        if not paused or any(s['status'] != 'paused' or s['mode'] != 'lowLatency' for s in paused):
            violations.add('pause_intent_lost')
        for key, error in [('rapidSwitchVerified', 'rapid_switch_unverified'),
                           ('staleStopVerified', 'stale_stop_unverified')]:
            if not result[key]:
                violations.add(error)
    commits = result.get('commits')
    require(isinstance(commits, list) and len(commits) <= 32)
    latencies, last_time, last_revision = [], -1, -1
    for commit in commits:
        require(isinstance(commit, dict) and commit.get('mode') in ('lowLatency', 'smoothPlayback') and
                number(commit.get('startedUs')) and number(commit.get('elapsedUs')) and
                commit['startedUs'] >= last_time and commit['elapsedUs'] >= commit['startedUs'] and
                type(commit.get('revision')) is int and commit['revision'] > last_revision)
        last_time, last_revision = commit['elapsedUs'], commit['revision']
        latencies.append(commit['elapsedUs']-commit['startedUs'])
    expected_commits = [] if scenario == 'baseline' else ['lowLatency', 'smoothPlayback']
    if [c['mode'] for c in commits] != expected_commits:
        violations.add('mode_commits_incomplete')
    for key in ('acceptedConnections', 'rejectedConnections', 'recordedConnections', 'activeConnections'):
        require(type(receipt.get(key)) is int and receipt[key] >= 0)
    require(type(receipt.get('cleaned')) is bool)
    require(receipt.get('timelineMode') == 'first-client-bytes' and
            receipt.get('byteScope') == 'downstream-tcp-including-protocol-headers')
    boundaries = receipt.get('phaseBoundariesMs')
    require(isinstance(boundaries, list) and 1 <= len(boundaries) <= 256 and boundaries[0] == 0 and
            all(type(v) is int and 0 <= v <= 86400000 for v in boundaries) and
            all(b > a for a, b in zip(boundaries, boundaries[1:])))
    require(isinstance(connections, list) and len(connections) <= 10000 and
            len(connections) == receipt['recordedConnections'])
    ids, phases, total = set(), [0]*len(boundaries), 0
    for row in connections:
        require(isinstance(row, dict) and row.get('schemaVersion') == 1 and
                all(row.get(k) == result[k] for k in identity))
        require(type(row.get('connectionId')) is int and row['connectionId'] not in ids)
        ids.add(row['connectionId'])
        require(row.get('outcome') in ('complete', 'cancelled', 'disconnected', 'timeout', 'io_error'))
        require((row.get('startMs') is None and row.get('endMs') is None) or
                (number(row.get('startMs')) and number(row.get('endMs')) and row['endMs'] >= row['startMs']))
        require(type(row.get('upstreamBytesWritten')) is int and row['upstreamBytesWritten'] >= 0 and
                type(row.get('downstreamBytesWritten')) is int and row['downstreamBytesWritten'] >= 0)
        require(isinstance(row.get('phaseBytes'), list) and len(row['phaseBytes']) == len(phases) and
                all(type(v) is int and v >= 0 for v in row['phaseBytes']) and
                sum(row['phaseBytes']) == row['downstreamBytesWritten'])
        total += row['downstreamBytesWritten']
        phases = [a+b for a, b in zip(phases, row['phaseBytes'])]
    require(ids == set(range(1, len(ids)+1)))
    server_complete = (receipt['cleaned'] and receipt['activeConnections'] == 0 and
                       receipt['acceptedConnections'] == len(connections) and
                       receipt['rejectedConnections'] == 0)
    def delta(key):
        values = [s[key] for s in samples]
        return (values[-1]-values[0] if values and all(v is not None for v in values) and
                all(b >= a for a, b in zip(values, values[1:])) else None)
    buffers = [s['managedBufferedUs'] for s in samples]
    return dict(schemaVersion=1, runId=result['runId'], protocol=result['protocol'],
                scenario=scenario, baselineMode=baseline_mode,
                outcome=result['outcome'], processExitCode=exit_code,
                captureComplete=(exit_code == 0 and result['outcome'] == 'completed' and
                                 result['cleaned'] and server_complete and total > 0 and not violations),
                violations=sorted(violations), modeSwitchLatencyUs=latencies,
                rebufferCountDelta=delta('rebufferCount'), rebufferDurationUsDelta=delta('rebufferUs'),
                reconnectCountDelta=delta('reconnectCount'), networkPhaseBytes=phases,
                networkPhasesObserved=[i for i, size in enumerate(phases) if size > 0],
                downstreamBytesWritten=total,
                maximumManagedBufferedUs=max(buffers) if buffers and all(v is not None for v in buffers) else None,
                maximumSampleGapUs=max((b['elapsedUs']-a['elapsedUs'] for a,b in zip(samples,samples[1:])), default=None),
                endToEndLatencyUs=None, capabilityAccepted=False, physicalOutputVerified=False,
                mediaIdentityVerified=False, baselineComparable=False)


def read_bounded(path, limit=16*1024*1024):
    with Path(path).open('rb') as source:
        data = source.read(limit+1)
    require(len(data) <= limit)
    return data.decode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('capture', 'connections', 'receipt', 'output'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--exit-code', type=int, required=True)
    args = parser.parse_args()
    try:
        samples, results = [], []
        for line in read_bounded(args.capture).splitlines():
            for marker, values in [('YL_LIVE_SAMPLE=', samples), ('YL_LIVE_RESULT=', results)]:
                if marker in line:
                    values.append(json.loads(line.split(marker, 1)[1]))
        require(len(results) == 1)
        report = summarize(results[0], samples, json.loads(read_bounded(args.receipt, 65536)),
                           [json.loads(v) for v in read_bounded(args.connections).splitlines()],
                           exit_code=args.exit_code)
        with args.output.open('x') as out:
            json.dump(report, out, indent=2); out.write('\n')
    except (ValueError, OSError, TypeError, KeyError):
        parser.exit(2, 'Invalid or mismatched live evidence\n')
    return 0 if report['captureComplete'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
