#!/usr/bin/env python3
"""Plan repeated owned ABR trials and summarize archived evidence offline."""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat

from summarize_capture import parse_capture, summarize

MODES = ('auto', 'caps', 'fixed')
CACHES = ('cold', 'warm', 'os-cache-uncontrolled')
STATUSES = ('not_run', 'eligible', 'timeout', 'failed', 'incomplete',
            'policy_violation', 'network_not_exercised', 'invalid_artifacts')
METRICS = ('firstFrameUs', 'rebufferCountDelta', 'rebufferDurationUsDelta',
           'observedGeometrySwitches', 'requestBodyBytesWritten', 'requestFailures',
           'maximumSampleGapUs', 'adaptationLatencyUs', 'endToEndLatencyUs')
LIMITS = dict(capture=16*1024*1024, requests=16*1024*1024, serverStdout=65536)


def require(condition):
    if not condition:
        raise ValueError('Invalid experiment manifest')


def token(value, maximum=80):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,%d}' % (maximum-1), value)


def digest(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)


def validate_conditions(conditions):
    labels = {'platform', 'device', 'os', 'architecture', 'deviceKind', 'buildMode', 'profileId'}
    hashes = {'sourceSha256', 'artifactSha256', 'dependencySha256', 'profileHash', 'mediaHash'}
    require(isinstance(conditions, dict) and set(conditions) == labels | hashes)
    require(all(token(conditions[k]) for k in labels) and all(digest(conditions[k]) for k in hashes))
    require(conditions['platform'] in ('android', 'ios', 'macos', 'windows', 'linux'))
    require(conditions['deviceKind'] in ('physical', 'simulator', 'emulator'))
    require(conditions['buildMode'] in ('debug', 'profile', 'release'))
    require(conditions['profileId'] == 'down-and-recover-v1')


def make_plan(experiment_id, conditions, attempts, caches):
    require(token(experiment_id, 40))
    validate_conditions(conditions)
    require(type(attempts) is int and 1 <= attempts <= 33)
    require(isinstance(caches, list) and caches and all(c in CACHES for c in caches))
    require(len(set(caches)) == len(caches) and attempts*len(caches)*len(MODES) <= 100)
    return dict(schemaVersion=1, experimentId=experiment_id, conditions=dict(conditions),
                attemptsPerMode=attempts, cacheStates=list(caches), trials=[
                    dict(runId=f'{experiment_id}-{mode}-{cache}-{attempt}', mode=mode,
                         cacheState=cache, attempt=attempt, artifacts=None, exitCode=None)
                    for mode in MODES for cache in caches for attempt in range(1, attempts+1)])


def validate_plan(plan):
    require(isinstance(plan, dict) and set(plan) == {'schemaVersion', 'experimentId', 'conditions',
            'attemptsPerMode', 'cacheStates', 'trials'})
    require(type(plan['schemaVersion']) is int and plan['schemaVersion'] == 1)
    template = make_plan(plan['experimentId'], plan['conditions'], plan['attemptsPerMode'], plan['cacheStates'])
    require(isinstance(plan['trials'], list) and len(plan['trials']) == len(template['trials']))
    expected = {(r['mode'], r['cacheState'], r['attempt']) for r in template['trials']}
    seen, ids = set(), set()
    for row in plan['trials']:
        require(isinstance(row, dict) and set(row) == set(template['trials'][0]))
        require(token(row['runId']) and row['runId'] not in ids)
        require(row['mode'] in MODES and row['cacheState'] in CACHES and type(row['attempt']) is int)
        key = (row['mode'], row['cacheState'], row['attempt'])
        require(key in expected and key not in seen)
        seen.add(key); ids.add(row['runId'])
        require(row['exitCode'] is None or type(row['exitCode']) is int)
        refs = row['artifacts']
        if refs is None:
            continue
        require(isinstance(refs, dict) and set(refs) == set(LIMITS))
        for ref in refs.values():
            require(isinstance(ref, dict) and set(ref) == {'path', 'sha256'} and digest(ref['sha256']))
            path = ref['path']
            require(isinstance(path, str) and 0 < len(path) <= 240 and '\\' not in path and '\x00' not in path)
            require(not PurePosixPath(path).is_absolute() and all(p not in ('', '.', '..') for p in path.split('/')))


class ArtifactError(Exception):
    pass


def read_verified(root, ref, limit, budget):
    """Open each path component without following symlinks; hash the same bytes we parse."""
    descriptor = None
    try:
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parts = ref['path'].split('/')
        for index, part in enumerate(parts):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if index < len(parts)-1:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ArtifactError('unsafe_artifact')
        if info.st_size > limit or info.st_size > budget[0]:
            raise ArtifactError('artifact_limit')
        with os.fdopen(descriptor, 'rb') as stream:
            descriptor = None
            raw = stream.read(min(limit, budget[0])+1)
        budget[0] -= len(raw)
        if len(raw) > limit or budget[0] < 0:
            raise ArtifactError('artifact_limit')
        if hashlib.sha256(raw).hexdigest() != ref['sha256']:
            raise ArtifactError('hash_mismatch')
        return raw.decode('utf-8')
    except FileNotFoundError:
        raise ArtifactError('missing_artifact') from None
    except OSError:
        raise ArtifactError('unsafe_artifact') from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def summarize_trial(trial, conditions, root, budget):
    report = {k: trial[k] for k in ('runId', 'mode', 'cacheState', 'attempt', 'exitCode')}
    if trial['artifacts'] is None:
        return dict(report, status='not_run' if trial['exitCode'] is None else 'failed', error='capture_missing')
    try:
        text = {k: read_verified(root, v, LIMITS[k], budget) for k, v in trial['artifacts'].items()}
        result, samples = parse_capture(text['capture'])
        require(isinstance(result, dict) and result.get('runId') == trial['runId'] and result.get('mode') == trial['mode'])
        require(all(result.get(k) == conditions[k] for k in ('platform', 'buildMode', 'profileId', 'profileHash', 'mediaHash')))
        requests = [json.loads(line) for line in text['requests'].splitlines()]
        server = [json.loads(line) for line in text['serverStdout'].splitlines()]
        require(len(server) == 2 and isinstance(server[0], dict) and
                server[0].get('runId') == trial['runId'] and server[0].get('profileSha256') == conditions['profileHash'] and
                server[0].get('timelineMode') == 'first-get')
        require(type(trial['exitCode']) is int)
        summary = summarize(result, samples, requests, exit_code=trial['exitCode'], server_summary=server[1])
        if summary['outcome'] == 'timeout':
            status = 'timeout'
        elif summary['outcome'] == 'failed' or trial['exitCode'] != 0:
            status = 'failed'
        elif not summary['captureComplete']:
            status = 'incomplete'
        elif summary['violations']:
            status = 'policy_violation'
        elif not summary['mediaRequestReachedRecovery']:
            status = 'network_not_exercised'
        else:
            status = 'eligible'
        return dict(report, status=status, summary=dict(summary, firstFrameUs=result.get('firstFrameUs')))
    except ArtifactError as error:
        return dict(report, status='invalid_artifacts', error=str(error))
    except (ValueError, TypeError, KeyError, RecursionError, OverflowError):
        return dict(report, status='invalid_artifacts', error='invalid_capture')


def counts(rows):
    values = Counter(row['status'] for row in rows)
    return {status: values[status] for status in STATUSES}


def distribution(values):
    observed = sorted(v for v in values if v is not None)
    def percentile(p):
        return observed[math.ceil(p*len(observed))-1] if observed else None
    return dict(observed=len(observed), unavailable=len(values)-len(observed), p50=percentile(.5), p95=percentile(.95))


def summarize_experiment(plan, root):
    validate_plan(plan)
    budget = [256*1024*1024]
    trials = [summarize_trial(row, plan['conditions'], Path(root), budget) for row in plan['trials']]
    cohorts = []
    for mode in MODES:
        for cache in plan['cacheStates']:
            rows = [r for r in trials if r['mode'] == mode and r['cacheState'] == cache]
            eligible = [r for r in rows if r['status'] == 'eligible']
            cohorts.append(dict(mode=mode, cacheState=cache, planned=len(rows), eligible=len(eligible),
                                excluded=len(rows)-len(eligible), statusCounts=counts(rows), metrics={
                                    k: distribution([r['summary'][k] for r in eligible]) for k in METRICS}))
    status_counts = counts(trials)
    return dict(schemaVersion=1, experimentId=plan['experimentId'], conditions=plan['conditions'],
                provenance='declared-conditions-and-hash-verified-archive', percentileMethod='nearest-rank',
                planned=len(trials), eligible=status_counts['eligible'],
                matrixComplete=status_counts['eligible'] == len(trials), statusCounts=status_counts,
                trials=trials, cohorts=cohorts, capabilityAccepted=False, baselineComparable=False,
                physicalOutputVerified=False)


def read_manifest(path):
    with path.open('rb') as stream:
        raw = stream.read(1024*1024+1)
    require(len(raw) <= 1024*1024)
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan')
    plan.add_argument('--conditions', type=Path, required=True)
    plan.add_argument('--id', required=True)
    plan.add_argument('--attempts', type=int, required=True)
    plan.add_argument('--cache-state', choices=CACHES, action='append')
    summary = sub.add_parser('summarize')
    summary.add_argument('--experiment', type=Path, required=True)
    for command in (plan, summary):
        command.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'plan':
            report = make_plan(args.id, read_manifest(args.conditions), args.attempts,
                               args.cache_state or ['os-cache-uncontrolled'])
            code = 0
        else:
            report = summarize_experiment(read_manifest(args.experiment), args.experiment.parent)
            code = 0 if report['matrixComplete'] else 1
        with args.output.open('x') as stream:
            json.dump(report, stream, indent=2, allow_nan=False); stream.write('\n')
        return code
    except (ValueError, TypeError, KeyError, OSError, RecursionError, OverflowError):
        parser.exit(2, 'Invalid experiment or unavailable output\n')


if __name__ == '__main__':
    raise SystemExit(main())
