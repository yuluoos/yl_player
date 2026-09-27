#!/usr/bin/env python3
"""Validate one complete, homogeneous benchmark run; never discard failed trials."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import sys

OUTCOMES = ('passed', 'failed', 'timeout', 'skipped', 'cancelled')
CONDITIONS = (
    'schemaVersion', 'runId', 'caseId', 'commit', 'sourceHash', 'dependencyHash',
    'artifactHash', 'mediaHash', 'platform', 'device', 'os', 'architecture',
    'deviceKind', 'buildMode', 'power', 'thermal', 'output', 'networkProfile',
    'cacheState', 'measurement', 'purpose', 'baselineComparable', 'plannedAttempts',
)
OBSERVATIONS = ('attempt', 'outcome', 'startedUs', 'firstPresentedUs', 'firstFrameUs')
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z')
SHA256 = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
MAX_ROWS = 10000
MAX_LINE_BYTES = 16384


def integer(value, minimum=0):
    return type(value) is int and minimum <= value <= (1 << 53) - 1


def summarize(rows: list[dict]) -> dict:
    """Summarize normalized observations; failed attempts stay in the denominator."""
    if not rows or len(rows) > MAX_ROWS:
        raise ValueError('invalid trial count')
    counts = dict.fromkeys(OUTCOMES, 0)
    samples = []
    for row in rows:
        if not isinstance(row, dict) or row.get('outcome') not in OUTCOMES:
            raise ValueError('invalid outcome')
        value = row.get('firstFrameUs')
        if value is not None and not integer(value):
            raise ValueError('invalid duration')
        counts[row['outcome']] += 1
        if row['outcome'] == 'passed':
            if value is None:
                raise ValueError('passed trial has no measurement')
            samples.append(value)
    samples.sort()
    stats = None if not samples else dict(
        n=len(samples), p50=statistics.median(samples),
        p95=samples[math.ceil(len(samples) * 0.95) - 1], maximum=samples[-1])
    return dict(attempts=len(rows), passed=counts['passed'], failed=counts['failed'],
                timeouts=counts['timeout'], skipped=counts['skipped'],
                cancelled=counts['cancelled'],
                nonPassRate=(len(rows) - counts['passed']) / len(rows), firstFrameUs=stats)


def validate_record(row):
    if not isinstance(row, dict) or set(row) != set(CONDITIONS + OBSERVATIONS):
        raise ValueError('missing or unexpected fields')
    if type(row['schemaVersion']) is not int or row['schemaVersion'] != 1:
        raise ValueError('unsupported schema')
    if type(row['baselineComparable']) is not bool:
        raise ValueError('invalid baseline comparability')
    for field in CONDITIONS:
        if field in ('schemaVersion', 'plannedAttempts', 'baselineComparable'):
            continue
        if not isinstance(row[field], str) or not TOKEN.fullmatch(row[field]):
            raise ValueError('unsafe or invalid identity')
    for field in ('sourceHash', 'dependencyHash', 'artifactHash', 'mediaHash'):
        if not SHA256.fullmatch(row[field]):
            raise ValueError('invalid content identity')
    if not COMMIT.fullmatch(row['commit']):
        raise ValueError('invalid commit identity')
    enums = {
        'platform': ('android', 'ios', 'macos'),
        'deviceKind': ('physical', 'simulator', 'emulator'),
        'buildMode': ('debug', 'profile', 'release'),
        'purpose': ('smoke', 'baseline'),
        'measurement': ('load-to-public-first-frame-event',),
        'cacheState': ('cold-controlled', 'warm', 'os-cache-uncontrolled'),
        'power': ('ac', 'battery', 'unknown'),
        'thermal': ('nominal', 'fair', 'serious', 'critical', 'unknown'),
    }
    for field, values in enums.items():
        if row[field] not in values:
            raise ValueError('invalid condition')
    if not integer(row['plannedAttempts'], 1) or row['plannedAttempts'] > MAX_ROWS:
        raise ValueError('invalid planned trials')
    if not integer(row['attempt'], 1) or row['attempt'] > row['plannedAttempts']:
        raise ValueError('invalid trial identity')
    if not integer(row['startedUs']):
        raise ValueError('invalid clock origin')
    timestamp, duration = row['firstPresentedUs'], row['firstFrameUs']
    if (timestamp is None) != (duration is None):
        raise ValueError('incomplete clock observation')
    if timestamp is not None:
        if not integer(timestamp) or not integer(duration) or timestamp - row['startedUs'] != duration:
            raise ValueError('inconsistent clock observation')
    if row['purpose'] == 'baseline' and (
            row['buildMode'] == 'debug' or row['deviceKind'] != 'physical'
            or row['thermal'] == 'unknown' or row['power'] == 'unknown'
            or row['cacheState'] == 'os-cache-uncontrolled'):
        raise ValueError('baseline requires controlled physical conditions')
    summarize([row])


def summarize_records(rows: list[dict]) -> dict:
    if not rows or len(rows) > MAX_ROWS:
        raise ValueError('invalid trial count')
    conditions = None
    attempts = set()
    for row in rows:
        validate_record(row)
        current = {field: row[field] for field in CONDITIONS}
        if conditions is not None and current != conditions:
            raise ValueError('mixed run conditions')
        conditions = current
        if row['attempt'] in attempts:
            raise ValueError('duplicate trial')
        attempts.add(row['attempt'])
    if attempts != set(range(1, conditions['plannedAttempts'] + 1)):
        raise ValueError('incomplete run; missing trials must be explicitly recorded')
    return dict(conditions=conditions, summary=summarize(rows))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError('nonfinite JSON constant')


def read_records(path):
    rows = []
    with Path(path).open('rb') as stream:
        while True:
            line = stream.readline(MAX_LINE_BYTES + 1)
            if not line:
                break
            if len(line) > MAX_LINE_BYTES or len(rows) >= MAX_ROWS:
                raise ValueError('input limit exceeded')
            if not line.strip():
                raise ValueError('empty record')
            rows.append(json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', help='JSONL for one complete run with fixed conditions')
    args = parser.parse_args()
    try:
        result = summarize_records(read_records(args.input))
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        # Never print input lines, identities or parser exceptions: they may hold secrets.
        print('Invalid benchmark records; check schema, identities, conditions and trial completeness.', file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
