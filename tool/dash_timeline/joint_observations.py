"""Summarize owned P01 native observations; missing output stays explicitly missing.

The Apple native observer pairs published pixels with rendered audio node time.
Android pairs actual ImageReader pixels with AudioTrack consumption and retains
both raw and rate-1 projected clocks at the codec's requested release instant.
Neither is a measurement of physical speakers or display scanout. Input files
and test outcomes must accompany summaries. Optional frozen limits check only
the stated local measurement envelope, not overall feature acceptance.
"""
import argparse
import json
import math
from pathlib import Path


def _reject_constant(value):
    raise ValueError(f'Non-finite observation: {value}')


def decode_records(text):
    records = []
    android = {}
    for line in text.splitlines():
        if 'YL_P01_JOINT ' in line:
            payload = line.split('YL_P01_JOINT ', 1)[1]
            kind = 'apple'
        elif 'P01_JOINT_ROW' in line or 'P01_JOINT:' in line or 'P01_JOINT ' in line:
            if '{' not in line:
                continue
            payload = line[line.index('{'):]
            kind = 'android-row' if 'P01_JOINT_ROW' in line else 'android-header'
        elif line.lstrip().startswith('{'):
            payload = line
            kind = 'apple'
        else:
            continue
        record = json.loads(payload, parse_constant=_reject_constant)
        key = (record['fixture'], record['run'])
        if kind == 'android-row':
            if key not in android:
                raise ValueError('Android row has no matching run header')
            android[key]['rows'].append(record)
        else:
            if kind == 'android-header':
                if key in android:
                    raise ValueError('Duplicate Android run header')
                record['rows'] = []
                android[key] = record
            records.append(record)
    return records


def _stats(values, signed=False):
    if not values:
        return None
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in values):
        raise ValueError('Invalid scalar observation')
    ordered = sorted(abs(v) for v in values) if signed else sorted(values)
    result = {'minimum': min(values), 'maximum': max(values)}
    if signed:
        result.update(absoluteMaximum=ordered[-1], absoluteP95=ordered[math.ceil(len(ordered) * .95) - 1])
    else:
        result['p95'] = ordered[math.ceil(len(ordered) * .95) - 1]
    return result


def summarize(records, legacy_apple_wait_ms=False):
    seen = set()
    groups = {}
    for record in records:
        key = (record['fixture'], record['run'])
        if key in seen:
            raise ValueError('Duplicate fixture/run; keep failed attempts in separate input files')
        seen.add(key)
        groups.setdefault(record['fixture'], []).append(record)
    result = {}
    for name, runs in groups.items():
        rows = [row for run in runs for row in run['rows']]
        waits = []
        transition_gaps = []
        for run in runs:
            previous = None
            for row in run['rows']:
                identity = row.get('epoch', row.get('representation'))
                host_ns = row.get('imageTimestampNs')
                if host_ns is None and row.get('observedHostUs') is not None:
                    host_ns = row['observedHostUs'] * 1000
                pts = row.get('videoPtsUs')
                if identity is None or host_ns is None or pts is None:
                    previous = None
                    continue
                if previous is not None and identity != previous[0]:
                    transition_gaps.append((host_ns - previous[1]) / 1_000_000 - (pts - previous[2]) / 1000)
                previous = (identity, host_ns, pts)
        for run in runs:
            for wait in run.get('periodWaits', []):
                if 'waitMs' in wait:
                    waits.append(wait['waitMs'])
                elif legacy_apple_wait_ms and 'waitUs' in wait:
                    # First macOS probe mislabeled the existing observer's ms.
                    # Explicit opt-in records the correction without altering raw evidence.
                    waits.append(wait['waitUs'])
                else:
                    raise ValueError('Period wait unit is ambiguous')
        result[name] = {
            'runs': len(runs), 'rows': len(rows),
            'missingAudioPairs': sum(row.get('deltaUs') is None for row in rows),
            'deltaUs': _stats([row['deltaUs'] for row in rows if row.get('deltaUs') is not None], signed=True),
            'rawDeltaUs': _stats([row['rawDeltaUs'] for row in rows if row.get('rawDeltaUs') is not None], signed=True),
            'periodWaitMs': _stats(waits),
            'transitionOutputGapExcessMs': _stats(transition_gaps),
            **{key: _stats([run[key] for run in runs if run.get(key) is not None])
               for key in ['readyMs', 'elapsedMs', 'peakBytes', 'releasedBytes']},
        }
    return result


def check_limits(summary, limits):
    """Check a previously frozen local envelope; never turn unmeasured data into zero."""
    if set(summary) != set(limits['fixtures']):
        raise ValueError('Fixture coverage differs from frozen protocol')
    for name, measured in summary.items():
        if measured['runs'] != limits['runs'] or measured['missingAudioPairs'] != 0:
            raise ValueError(f'{name}: incomplete observed run/pair coverage')
        delta = measured['deltaUs']
        if delta is None or delta['absoluteMaximum'] > limits['maxAbsoluteDeltaUs']:
            raise ValueError(f'{name}: outside frozen native AV pair envelope')
        gap = measured['transitionOutputGapExcessMs']
        if gap is not None and gap['maximum'] > limits['maxOutputGapExcessMs']:
            raise ValueError(f'{name}: outside frozen cross-Period output gap envelope')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--legacy-apple-wait-ms', action='store_true')
    parser.add_argument('--limits', type=Path)
    parser.add_argument('--platform', choices=['android', 'ios', 'macos'])
    args = parser.parse_args()
    records = decode_records(args.input.read_text())
    if not records:
        raise SystemExit('No owned P01 observation records found')
    measured = summarize(records, args.legacy_apple_wait_ms)
    gate = None
    if args.limits:
        if args.platform is None:
            parser.error('--limits requires --platform')
        limits = json.loads(args.limits.read_text())[args.platform]
        try:
            check_limits(measured, limits)
            gate = {'passed': True}
        except ValueError as error:
            gate = {'passed': False, 'reason': str(error)}
    args.output.write_text(json.dumps({'input': str(args.input),
        'legacyAppleWaitLabelCorrectedToMs': args.legacy_apple_wait_ms,
        'summary': measured, 'frozenGate': gate}, indent=2) + '\n')
    if gate is not None and not gate['passed']:
        raise SystemExit(gate['reason'])
