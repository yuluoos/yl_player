#!/usr/bin/env python3
"""Source-bound P08 measurements and write-once baseline gates. Never infer missing data."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys

from summarize import TOKEN, SHA256, COMMIT, OUTCOMES, unique_object, reject_constant

MAX_BYTES = 16 * 1024 * 1024
MAX_TRIALS = 10000
BOUNDARIES = {
    'compositor-capture': ('us',), 'public-state': ('us',), 'public-event': ('us',), 'output-presented': ('us',),
    'command-completed': ('us',), 'phase-clock': ('us',),
    'seek-output-stable': ('us',), 'source-to-output': ('us',),
    'calibrated-output': ('us',), 'process-sample': ('bytes', 'percent', 'celsius'),
    'media-ledger': ('bytes', 'us'), 'script-heap': ('bytes',),
    'gpu-observation': ('bytes', 'percent'), 'buffering-state': ('us', 'count', 'ratio'),
    'lifecycle-observation': ('bytes', 'count', 'us'),
}


def require(condition):
    if not condition:
        raise ValueError('invalid performance evidence')


def fields(value, names, optional=''):
    require(isinstance(value, dict))
    required, allowed = set(names.split()), set((names+' '+optional).split())
    require(required <= set(value) <= allowed)


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 2**53-1


def integer(value, minimum=0, maximum=2**53-1):
    return type(value) is int and minimum <= value <= maximum


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def label(value):
    require(isinstance(value, str) and TOKEN.fullmatch(value))


def hash_value(value):
    require(isinstance(value, str) and SHA256.fullmatch(value))


def validate_run(run):
    fields(run, 'schemaVersion runId commit sourceHash dependencyHash artifactHash conditions '
        'qualification baselineComparable plannedAttempts warmupAttempts metrics trials')
    require(type(run['schemaVersion']) is int and run['schemaVersion'] == 1)
    label(run['runId'])
    require(isinstance(run['commit'], str) and COMMIT.fullmatch(run['commit']))
    for name in ('sourceHash', 'dependencyHash', 'artifactHash'): hash_value(run[name])
    conditions=run['conditions']
    fields(conditions, 'caseId platform device os architecture deviceKind buildMode power thermal '
        'output mediaHash networkProfile cacheState protocolHash', 'apiLevel processBits memoryClass')
    for key, value in conditions.items():
        if key not in ('apiLevel','processBits'): label(value)
    if 'apiLevel' in conditions: require(integer(conditions['apiLevel'],1,1000))
    if 'processBits' in conditions: require(type(conditions['processBits']) is int and conditions['processBits'] in (32,64))
    if 'memoryClass' in conditions: require(conditions['memoryClass'] in ('low','standard','unknown'))
    for name in ('mediaHash','protocolHash'): hash_value(conditions[name])
    enums = dict(platform=('android','ios','macos'), deviceKind=('physical','simulator','emulator'),
        buildMode=('debug','profile','release'), power=('ac','battery','unknown'),
        thermal=('nominal','fair','serious','critical','unknown'),
        cacheState=('warm','cold-controlled','os-cache-uncontrolled'))
    for name, values in enums.items(): require(conditions[name] in values)
    qualification=run['qualification']
    fields(qualification,'contentVerified evidenceHash')
    require(type(qualification['contentVerified']) is bool)
    if qualification['evidenceHash'] is not None: hash_value(qualification['evidenceHash'])
    require(type(run['baselineComparable']) is bool)
    require(integer(run['plannedAttempts'],1,MAX_TRIALS))
    require(integer(run['warmupAttempts'],0,run['plannedAttempts']-1))
    metrics=run['metrics']
    require(isinstance(metrics,dict) and 0<len(metrics)<=64)
    for name, metric in metrics.items():
        label(name); fields(metric,'unit boundary','calibrationHash sourceClockHash')
        require(isinstance(metric['boundary'],str) and metric['boundary'] in BOUNDARIES)
        require(metric['unit'] in BOUNDARIES[metric['boundary']])
        for key in ('calibrationHash','sourceClockHash'):
            if key in metric: hash_value(metric[key])
    trials=run['trials']
    require(isinstance(trials,list) and len(trials)==run['plannedAttempts'])
    previous_end=0
    for index, trial in enumerate(trials,1):
        fields(trial,'attempt outcome cleanup startedUs endedUs values')
        require(type(trial['attempt']) is int and trial['attempt']==index)
        require(trial['outcome'] in OUTCOMES and trial['cleanup'] in ('passed','failed','unknown'))
        require(integer(trial['startedUs']) and integer(trial['endedUs']))
        require(previous_end<=trial['startedUs']<=trial['endedUs']); previous_end=trial['endedUs']
        require(isinstance(trial['values'],dict) and set(trial['values'])==set(metrics))
        for name, value in trial['values'].items():
            require(value is None or number(value))
            if value is not None and metrics[name]['unit']=='ratio': require(value<=1)
            if value is not None and metrics[name]['unit'] in ('bytes','count'): require(integer(value))


def stats(values):
    if not values: return None
    ordered=sorted(values)
    return dict(n=len(values),p50=statistics.median(ordered),
                p95=ordered[math.ceil(len(ordered)*.95)-1],maximum=ordered[-1])


def summarize_run(run):
    validate_run(run)
    trials=run['trials']; warmups=run['warmupAttempts']
    counts={outcome:sum(t['outcome']==outcome for t in trials) for outcome in OUTCOMES}
    successful=lambda t: t['outcome']=='passed' and t['cleanup']=='passed'
    return dict(attempts=len(trials),warmups=warmups,outcomes=counts,
        nonPasses=sum(not successful(t) for t in trials),
        cleanupNonPasses=sum(t['cleanup']!='passed' for t in trials),
        metrics={name:stats([t['values'][name] for t in trials[warmups:]
            if successful(t) and t['values'][name] is not None]) for name in run['metrics']})


def validate_policy(policy, run):
    fields(policy,'schemaVersion version minimumSamples maximumNonPasses limits')
    require(type(policy['schemaVersion']) is int and policy['schemaVersion']==1)
    label(policy['version'])
    require(integer(policy['minimumSamples'],1,MAX_TRIALS))
    require(integer(policy['maximumNonPasses'],0,run['plannedAttempts']-1))
    limits=policy['limits']
    require(isinstance(limits,dict) and 0<len(limits)<=len(run['metrics']))
    for name, limit in limits.items():
        require(name in run['metrics'])
        fields(limit,'p50 p95 maximum maxRegressionRatio')
        require(all(number(limit[key]) for key in ('p50','p95','maximum')))
        require(limit['p50']<=limit['p95']<=limit['maximum'])
        require(limit['maxRegressionRatio'] is None or number(limit['maxRegressionRatio']))


def qualify(run, policy):
    validate_run(run); validate_policy(policy, run)
    require(run['qualification']['contentVerified'])
    hash_value(run['qualification']['evidenceHash'])
    conditions=run['conditions']
    require(conditions['buildMode']!='debug' and conditions['thermal']=='nominal'
            and conditions['power']!='unknown')
    # Exact observation boundaries remain in the freeze. Event receipt is never
    # admitted as output presentation, even on a physical device.
    for name in policy['limits']:
        metric=run['metrics'][name]
        if metric['boundary'] in ('output-presented','seek-output-stable','calibrated-output','source-to-output'):
            hash_value(metric.get('calibrationHash'))
            require(conditions['deviceKind']=='physical')
        if metric['boundary']=='source-to-output': hash_value(metric.get('sourceClockHash'))


def freeze(baseline, policy):
    qualify(baseline,policy)
    summary=summarize_run(baseline)
    require(summary['nonPasses']<=policy['maximumNonPasses'])
    require(all(summary['metrics'][name] is not None and
                summary['metrics'][name]['n']>=policy['minimumSamples'] for name in policy['limits']))
    # Copy by serialization so callers cannot mutate the baseline through aliases.
    value=json.loads(canonical(dict(schemaVersion=1,baseline=baseline,policy=policy)))
    value['sha256']=digest(value)
    return value


def validate_frozen(frozen):
    fields(frozen,'schemaVersion baseline policy sha256')
    require(type(frozen['schemaVersion']) is int and frozen['schemaVersion']==1)
    hash_value(frozen['sha256'])
    require(frozen['sha256']==digest({k:v for k,v in frozen.items() if k!='sha256'}))
    require(freeze(frozen['baseline'],frozen['policy'])==frozen)


def evaluate(candidate, frozen):
    validate_frozen(frozen)
    baseline,policy=frozen['baseline'],frozen['policy']
    qualify(candidate,policy)
    for name in ('conditions','metrics','dependencyHash','plannedAttempts','warmupAttempts','baselineComparable'):
        require(candidate[name]==baseline[name])
    old,new=summarize_run(baseline),summarize_run(candidate)
    results={}
    for name, limits in policy['limits'].items():
        before,after=old['metrics'][name],new['metrics'][name]
        failures=[]; improvement=None
        if after is None or after['n']<policy['minimumSamples']: failures.append('insufficient-samples')
        if after is not None:
            failures.extend(key for key in ('p50','p95','maximum') if after[key]>limits[key])
            if candidate['baselineComparable']:
                if before['p95']>0: improvement=1-after['p95']/before['p95']
                ratio=limits['maxRegressionRatio']
                if ratio is not None and after['p95']>before['p95']*(1+ratio): failures.append('regression')
        results[name]=dict(boundary=candidate['metrics'][name]['boundary'],unit=candidate['metrics'][name]['unit'],
            baseline=before,candidate=after,improvementRatio=improvement,failures=failures)
    return dict(schemaVersion=1,version=policy['version'],frozenHash=frozen['sha256'],
        baselineSourceHash=baseline['sourceHash'],candidateSourceHash=candidate['sourceHash'],
        summary=new,metrics=results,passed=new['nonPasses']<=policy['maximumNonPasses']
        and all(not result['failures'] for result in results.values()),
        presentationMetricSelected=any(candidate['metrics'][name]['boundary']=='output-presented' for name in results),
        releaseReady=False)  # This individual metric gate cannot accept the release.


def read_json(path):
    with Path(path).open('rb') as stream: data=stream.read(MAX_BYTES+1)
    require(len(data)<=MAX_BYTES)
    return json.loads(data, object_pairs_hook=unique_object,parse_constant=reject_constant)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    summary=sub.add_parser('summarize'); summary.add_argument('run')
    freeze_parser=sub.add_parser('freeze')
    for name in ('run','policy','output'): freeze_parser.add_argument(name)
    compare=sub.add_parser('check'); compare.add_argument('run');compare.add_argument('frozen')
    args=parser.parse_args()
    try:
        run=read_json(args.run)
        if args.command=='summarize': result=summarize_run(run)
        elif args.command=='freeze':
            result=freeze(run,read_json(args.policy))
            with Path(args.output).open('x') as target:
                target.write(json.dumps(result,sort_keys=True,indent=2,allow_nan=False)+'\n')
            result={'frozenHash':result['sha256'],'version':result['policy']['version']}
        else: result=evaluate(run,read_json(args.frozen))
        print(json.dumps(result,sort_keys=True,indent=2,allow_nan=False))
        return 1 if args.command=='check' and not result['passed'] else 0
    except (OSError,ValueError,TypeError,KeyError,RecursionError):
        print('Invalid performance evidence; check schema, conditions, qualification and frozen identity.',file=sys.stderr)
        return 2

if __name__=='__main__': sys.exit(main())
