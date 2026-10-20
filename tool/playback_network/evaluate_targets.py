#!/usr/bin/env python3
"""Freeze explicit P08 targets after a baseline; compare recomputed raw evidence.

Threshold comparison is not physical output or capability certification.
"""
import argparse
import hashlib
import json
from pathlib import Path
from aggregate_experiment import digest, read_manifest, require, summarize_experiment
from summarize_capture import number

IDENTITY = ('platform', 'device', 'os', 'architecture', 'deviceKind', 'buildMode',
            'dependencySha256', 'profileId', 'profileHash', 'mediaHash')


def key(cohort):
    return cohort['mode'], cohort['cacheState']


def validate_limits(limits, report):
    require(isinstance(limits, list) and 1 <= len(limits) <= 100)
    require(isinstance(report.get('cohorts'), list))
    cohorts = {key(c): c for c in report['cohorts']}
    require(len(cohorts) == len(report['cohorts']))
    seen = set()
    for limit in limits:
        require(isinstance(limit, dict) and set(limit) ==
                {'mode', 'cacheState', 'minimumSamples', 'maxima'})
        identity = key(limit)
        require(identity in cohorts and identity not in seen)
        seen.add(identity)
        require(type(limit['minimumSamples']) is int and 1 <= limit['minimumSamples'] <= 100)
        maxima = limit['maxima']
        require(isinstance(maxima, dict) and maxima and
                all(k in cohorts[identity]['metrics'] and number(v) for k, v in maxima.items()))
    require(seen == set(cohorts))
    return cohorts


def freeze(baseline, baseline_sha256, limits):
    require(digest(baseline_sha256) and baseline.get('matrixComplete') is True)
    cohorts = validate_limits(limits, baseline)
    for limit in limits:
        cohort = cohorts[key(limit)]
        require(cohort['excluded'] == 0 and cohort['eligible'] >= limit['minimumSamples'])
        for metric in limit['maxima']:
            values = cohort['metrics'][metric]
            require(values['unavailable'] == 0 and values['observed'] >= limit['minimumSamples'] and
                    number(values['p95']))
    return dict(schemaVersion=1, baselineSha256=baseline_sha256,
                conditions=dict(baseline['conditions']), limits=limits,
                statistic='p95-nearest-rank', thresholdSource='explicit-input',
                capabilityAccepted=False)


def compare(targets, candidate):
    require(targets.get('schemaVersion') == 1 and digest(targets.get('baselineSha256')) and
            targets.get('statistic') == 'p95-nearest-rank' and
            targets.get('thresholdSource') == 'explicit-input')
    require(all(k in targets['conditions'] and candidate['conditions'].get(k) == targets['conditions'][k]
                for k in IDENTITY))
    cohorts = validate_limits(targets['limits'], candidate)
    rows = []
    for limit in targets['limits']:
        cohort = cohorts[key(limit)]
        for metric, maximum in limit['maxima'].items():
            values = cohort['metrics'][metric]
            available = (cohort['excluded'] == 0 and cohort['eligible'] >= limit['minimumSamples'] and
                         values['observed'] >= limit['minimumSamples'] and values['unavailable'] == 0 and
                         number(values['p95']))
            status = 'unavailable' if not available else ('passed' if values['p95'] <= maximum else 'failed')
            rows.append(dict(mode=limit['mode'], cacheState=limit['cacheState'], metric=metric,
                             maximumP95=maximum, measuredP95=values['p95'], status=status,
                             planned=cohort['planned'], eligible=cohort['eligible'], excluded=cohort['excluded']))
    status = ('failed' if any(r['status'] == 'failed' for r in rows) else
              'passed' if candidate.get('matrixComplete') is True and all(r['status'] == 'passed' for r in rows)
              else 'unavailable')
    return dict(schemaVersion=1, status=status, checks=rows,
                baselineSha256=targets['baselineSha256'], conditions=candidate['conditions'],
                comparisonScope='declared-conditions-and-raw-archive',
                capabilityAccepted=False, physicalOutputVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['freeze', 'compare'])
    parser.add_argument('--experiment', type=Path, required=True)
    parser.add_argument('--limits', type=Path)
    parser.add_argument('--targets', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        plan = read_manifest(args.experiment)
        if plan.get('kind') == 'live':
            from aggregate_live import summarize_experiment as summarize_live_experiment
            report = summarize_live_experiment(plan, args.experiment.parent)
        else:
            report = summarize_experiment(plan, args.experiment.parent)
        if args.command == 'freeze':
            require(args.limits is not None and args.targets is None)
            # Bind the exact validated manifest object; its entries bind raw logs.
            canonical = json.dumps(plan, sort_keys=True, separators=(',', ':')).encode()
            output = freeze(report, hashlib.sha256(canonical).hexdigest(), read_manifest(args.limits))
            code = 0
        else:
            require(args.targets is not None and args.limits is None)
            output = compare(read_manifest(args.targets), report)
            code = 0 if output['status'] == 'passed' else 1
        with args.output.open('x') as destination:
            json.dump(output, destination, indent=2, allow_nan=False); destination.write('\n')
        return code
    except (ValueError, OSError, KeyError, TypeError):
        parser.exit(2, 'Invalid baseline, explicit limits or incompatible conditions\n')

if __name__ == '__main__':
    raise SystemExit(main())
