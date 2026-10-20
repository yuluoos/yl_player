#!/usr/bin/env python3
"""Predeclare HLS/FLV/RTMP mode-switch trials and recompute hash-bound raw logs."""
import argparse
import json
from pathlib import Path, PurePosixPath
from aggregate_experiment import (ArtifactError, CACHES, counts, digest, distribution,
    read_manifest, read_verified, require, token, validate_conditions)
from summarize_live import summarize

PROTOCOLS = ('hls', 'flv', 'rtmp')
MODES = ('smoothPlayback', 'lowLatency')
LIMITS = dict(capture=16*1024*1024, connections=16*1024*1024, receipt=65536)
METRICS = ('rebufferCountDelta', 'rebufferDurationUsDelta',
           'reconnectCountDelta', 'maximumManagedBufferedUs', 'maximumSampleGapUs')


def make_plan(identity, conditions, attempts, caches):
    require(token(identity, 30))
    validate_conditions(conditions)
    require(type(attempts) is int and 1 <= attempts <= 16)
    require(isinstance(caches, list) and caches and all(c in CACHES for c in caches) and
            len(set(caches)) == len(caches) and len(caches)*6*attempts <= 100)
    return dict(schemaVersion=1, kind='live', experimentId=identity, conditions=conditions,
                attemptsPerProtocol=attempts, cacheStates=caches, trials=[
                    dict(runId=f'{identity}-{protocol}-{mode}-{cache}-{attempt}', protocol=protocol, baselineMode=mode,
                         cacheState=cache, attempt=attempt, exitCode=None, artifacts=None)
                    for protocol in PROTOCOLS for mode in MODES for cache in caches for attempt in range(1, attempts+1)])


def validate(plan):
    require(isinstance(plan, dict) and plan.get('schemaVersion') == 1 and plan.get('kind') == 'live')
    template = make_plan(plan['experimentId'], plan['conditions'], plan['attemptsPerProtocol'], plan['cacheStates'])
    require(set(template) == set(plan) and isinstance(plan['trials'], list) and
            len(plan['trials']) == len(template['trials']))
    expected = {(t['protocol'], t['baselineMode'], t['cacheState'], t['attempt']) for t in template['trials']}
    seen, ids = set(), set()
    for trial in plan['trials']:
        require(isinstance(trial, dict) and set(trial) == set(template['trials'][0]))
        require(type(trial['attempt']) is int)
        key = (trial['protocol'], trial['baselineMode'], trial['cacheState'], trial['attempt'])
        require(key in expected and key not in seen and token(trial['runId']) and trial['runId'] not in ids)
        seen.add(key); ids.add(trial['runId'])
        require(trial['exitCode'] is None or type(trial['exitCode']) is int)
        refs = trial['artifacts']
        if refs is not None:
            require(isinstance(refs, dict) and set(refs) == set(LIMITS))
            for ref in refs.values():
                require(isinstance(ref, dict) and set(ref) == {'path', 'sha256'} and digest(ref['sha256']))
                path = ref['path']
                require(isinstance(path, str) and 0 < len(path) <= 240 and '\\' not in path and '\x00' not in path and
                        not PurePosixPath(path).is_absolute() and all(p not in ('', '.', '..') for p in path.split('/')))


def trial_summary(trial, conditions, root, budget):
    output = {k: trial[k] for k in ('runId', 'protocol', 'baselineMode', 'cacheState', 'attempt', 'exitCode')}
    if trial['artifacts'] is None:
        return dict(output, status='not_run' if trial['exitCode'] is None else 'failed')
    try:
        raw = {k: read_verified(root, ref, LIMITS[k], budget) for k, ref in trial['artifacts'].items()}
        results, samples = [], []
        for line in raw['capture'].splitlines():
            for marker, destination in [('YL_LIVE_RESULT=', results), ('YL_LIVE_SAMPLE=', samples)]:
                if marker in line:
                    destination.append(json.loads(line.split(marker, 1)[1]))
        require(len(results) == 1)
        result = results[0]
        require(isinstance(result, dict))
        require(result.get('scenario') == 'baseline' and result.get('baselineMode') == trial['baselineMode'])
        require(result.get('runId') == trial['runId'] and result.get('protocol') == trial['protocol'])
        require(all(result.get(k) == conditions[k] for k in ('profileId', 'profileHash', 'platform', 'buildMode')) and
                result.get('declaredMediaHash') == conditions['mediaHash'])
        receipt = json.loads(raw['receipt'])
        summary = summarize(result, samples, receipt,
            [json.loads(line) for line in raw['connections'].splitlines()], exit_code=trial['exitCode'])
        if summary['outcome'] == 'timeout': status = 'timeout'
        elif summary['outcome'] == 'failed' or trial['exitCode'] != 0: status = 'failed'
        elif summary['violations']: status = 'policy_violation'
        elif not summary['captureComplete']: status = 'incomplete'
        elif len(summary['networkPhasesObserved']) != len(receipt['phaseBoundariesMs']): status = 'network_not_exercised'
        else: status = 'eligible'
        summary['modeSwitchMaxUs'] = max(summary['modeSwitchLatencyUs'], default=None)
        return dict(output, status=status, summary=summary)
    except ArtifactError as error:
        return dict(output, status='invalid_artifacts', error=str(error))
    except (ValueError, KeyError, TypeError, OverflowError, RecursionError):
        return dict(output, status='invalid_artifacts', error='invalid_capture')


def summarize_experiment(plan, root):
    validate(plan)
    budget = [256*1024*1024]
    trials = [trial_summary(t, plan['conditions'], root, budget) for t in plan['trials']]
    cohorts = []
    for protocol in PROTOCOLS:
        for mode in MODES:
            for cache in plan['cacheStates']:
                rows = [t for t in trials if t['protocol'] == protocol and
                        t['baselineMode'] == mode and t['cacheState'] == cache]
                eligible = [t for t in rows if t['status'] == 'eligible']
                cohorts.append(dict(mode=protocol+'-'+mode, cacheState=cache,
                    planned=len(rows), eligible=len(eligible), excluded=len(rows)-len(eligible),
                    statusCounts=counts(rows), metrics={k: distribution([t['summary'][k] for t in eligible]) for k in METRICS}))
    status = counts(trials)
    return dict(schemaVersion=1, kind='live', experimentId=plan['experimentId'], conditions=plan['conditions'],
        planned=len(trials), eligible=status['eligible'], statusCounts=status,
        matrixComplete=status['eligible'] == len(trials), trials=trials, cohorts=cohorts,
        percentileMethod='nearest-rank', capabilityAccepted=False, physicalOutputVerified=False,
        baselineComparable=False, mediaIdentityVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan')
    plan.add_argument('--id', required=True)
    plan.add_argument('--conditions', type=Path, required=True)
    plan.add_argument('--attempts', type=int, required=True)
    plan.add_argument('--cache-state', choices=CACHES, action='append')
    summary = sub.add_parser('summarize')
    summary.add_argument('--experiment', type=Path, required=True)
    for command in (plan, summary): command.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'plan':
            output = make_plan(args.id, read_manifest(args.conditions), args.attempts,
                               args.cache_state or ['os-cache-uncontrolled'])
            code = 0
        else:
            output = summarize_experiment(read_manifest(args.experiment), args.experiment.parent)
            code = 0 if output['matrixComplete'] else 1
        with args.output.open('x') as out:
            json.dump(output, out, indent=2, allow_nan=False); out.write('\n')
        return code
    except (ValueError, OSError, KeyError, TypeError):
        parser.exit(2, 'Invalid live experiment or unavailable output\n')

if __name__ == '__main__': raise SystemExit(main())
