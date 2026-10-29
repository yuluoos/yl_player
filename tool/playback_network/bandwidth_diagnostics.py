#!/usr/bin/env python3
"""Describe owned-fixture request goodput without changing ABR acceptance.

Server write intervals include application latency and scheduler/queue overhead.
Their union is an activity measurement, not link capacity or a replacement for
AVPlayer's transferDuration. Server and device clocks are not subtracted.
"""
import argparse
import json
import math
from pathlib import Path

from abr_accesslog import read_rows, summarize_policy
from network_profile import load_profiles


def summarize_requests(rows, profile):
    def require(value):
        if not value:
            raise ValueError('invalid bandwidth request evidence')

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0

    require(isinstance(rows, list) and 0 < len(rows) <= 10000)
    boundaries = [step['atMs'] for step in profile.steps]
    selected = [[] for _ in boundaries]
    excluded = dict(crossPhase=0, incompleteOrNonBody=0)
    identities = set()
    identity = None
    for row in rows:
        require(isinstance(row, dict))
        require(type(row.get('schemaVersion')) is int and row['schemaVersion'] == 1)
        require(row.get('profile') == profile.id and row.get('profileSha256') == profile.sha256)
        require(row.get('phaseBoundariesMs') == boundaries)
        ident = row.get('requestId')
        require(type(ident) is int and ident > 0 and ident not in identities)
        identities.add(ident)
        require(row.get('timelineMode') in ('first-get', 'server-start'))
        require(row.get('runId') is None or isinstance(row['runId'], str))
        current = (row.get('runId'), row['timelineMode'])
        if identity is None:
            identity = current
        require(current == identity)
        size = row.get('bodyBytesWritten')
        phases = row.get('phaseBytesWritten')
        require(type(size) is int and size >= 0)
        require(isinstance(phases, list) and len(phases) == len(boundaries) and
                all(type(n) is int and n >= 0 for n in phases) and sum(phases) == size)
        require(row.get('method') in ('GET', 'HEAD'))
        require(row.get('outcome') in ('complete', 'disconnected', 'timeout', 'client_io_error'))
        if row.get('timelineState') == 'pending':
            require(row['method'] == 'HEAD' and row.get('startMs') is None and row.get('endMs') is None and size == 0)
            excluded['incompleteOrNonBody'] += 1
            continue
        require(row.get('timelineState') == 'active')
        start, end = row.get('startMs'), row.get('endMs')
        require(finite(start) and finite(end) and end >= start)
        if row['method'] != 'GET' or row['outcome'] != 'complete' or row.get('status') not in (200, 206) or size == 0:
            excluded['incompleteOrNonBody'] += 1
            continue
        require(end > start)
        index = max(i for i, boundary in enumerate(boundaries) if boundary <= start)
        if index+1 < len(boundaries) and end > boundaries[index+1]:
            excluded['crossPhase'] += 1
            continue
        selected[index].append(row)
    summaries = []
    for index, group in enumerate(selected):
        intervals = sorted((r['startMs'], r['endMs']) for r in group)
        total = sum(r['bodyBytesWritten'] for r in group)
        duration = sum(end-start for start, end in intervals)
        union = 0
        right = 0
        for start, end in intervals:
            union += max(0, end-max(start, right))
            right = max(right, end)
        summaries.append(dict(phaseIndex=index, startMs=boundaries[index],
            endMs=boundaries[index+1] if index+1 < len(boundaries) else None,
            requestCount=len(group), bodyBytesWritten=total,
            configuredCeilingBps=profile.steps[index]['bytesPerSecond']*8,
            configuredLatencySumMs=len(group)*profile.steps[index]['latencyMs'],
            requestDurationSumMs=duration, activeUnionMs=union,
            spanMs=max(end for _, end in intervals)-intervals[0][0] if intervals else None,
            requestWeightedGoodputBps=total*8000/duration if duration else None,
            activeUnionGoodputBps=total*8000/union if union else None))
    return dict(schemaVersion=1, profile=profile.id, profileSha256=profile.sha256,
        totalRequests=len(rows), excludedCounts=excluded, phases=summaries,
        capacityMeasured=False, capabilityAccepted=False,
        interpretation='Server write intervals only; overlapping request durations remain summed separately. No cross-clock subtraction or replacement of policy bandwidth.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--profiles', type=Path, default=Path(__file__).with_name('profiles.json'))
    args = parser.parse_args()
    requests = read_rows(args.capture/'requests.jsonl')
    if not requests:
        raise ValueError('no requests captured')
    profiles = load_profiles(args.profiles)
    profile = profiles.get(requests[0].get('profile'))
    if profile is None:
        raise ValueError('unknown captured profile')
    result = summarize_requests(requests, profile)
    # Keep existing policy validation and its original thresholds. This report
    # supplies explanations; it never overwrites a collector receipt or failure.
    policy = read_rows(args.capture/'policy-decisions.jsonl')
    if not policy:
        raise ValueError('no policy decisions captured')
    result['policy'] = summarize_policy(policy, expected_attempts=policy[-1].get('attempts'))
    from proxy_boundaries import proxy_trace_version, record_proxy_observation
    version = proxy_trace_version(read_rows(args.capture/'rows.jsonl'))
    if version in (1, 2, 3, 4, 5, 6):
        proxy_receipt = {'errors': []}
        record_proxy_observation(proxy_receipt, read_rows(args.capture/'proxy-requests.jsonl'), requests, version)
        result['errors'] = proxy_receipt['errors']
        if 'proxyRequestObservation' in proxy_receipt:
            result['proxy'] = proxy_receipt['proxyRequestObservation']
        if 'proxyRequestValidationErrors' in proxy_receipt:
            result['proxyRequestValidationErrors'] = proxy_receipt['proxyRequestValidationErrors']
    print(json.dumps(result, indent=2, allow_nan=False))
    return 1 if result.get('errors') else 0


if __name__ == '__main__':
    raise SystemExit(main())
