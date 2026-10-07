"""Process-wide resource instrumentation; never a decoder budget or SLO."""
import collections
import json
from pathlib import Path
import re
import sys
from summarize import unique_object, reject_constant

PHASES = ('idle', 'opening', 'playing', 'disposing', 'disposed')
FIELDS = set('phase monotonicUs cpuUs rssBytes footprintBytes thermal power status'.split())
TRIAL = set('schemaVersion runId attempt plannedAttempts pid buildMode intervalMs engine decoder outcome samples'.split())


def integer(v, minimum=0): return type(v) is int and minimum <= v <= 2**53-1


def summarize_series(trial):
    if not isinstance(trial, dict) or set(trial) != (TRIAL | {'workload'} if trial.get('schemaVersion') == 2 else TRIAL):
        raise ValueError('Invalid resource trial')
    if (type(trial['schemaVersion']) is not int or trial['schemaVersion'] not in (1,2)
        or not isinstance(trial['runId'],str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}',trial['runId'])
        or not integer(trial['pid'],1) or not integer(trial['attempt'],1)
        or not integer(trial['plannedAttempts'],1) or not 1 <= trial['attempt'] <= trial['plannedAttempts'] <= 100
        or trial['buildMode'] not in ('debug','profile','release') or trial['intervalMs'] != 250
        or trial['engine'] not in ('unknown','avPlayer','managedFallback')
        or trial['decoder'] not in ('unknown','hardware','software')
        or type(trial['intervalMs']) is not int
        or trial['outcome'] not in ('passed','failed','timeout','skipped')):
        raise ValueError('Invalid resource identity')
    workload=trial.get('workload','playback')
    if workload not in ('playback','harness-only') or (workload=='harness-only' and
        (trial['buildMode']!='profile' or trial['engine']!='unknown' or trial['decoder']!='unknown')):
        raise ValueError('Invalid resource workload')
    rows=trial['samples']
    if not isinstance(rows,list) or len(rows)>256 or not rows and trial['outcome']=='passed':
        raise ValueError('Invalid resource sample count')
    groups={}; previous=None; last_cpu=None; thermal=collections.Counter(); power=collections.Counter()
    for r in rows:
        if not isinstance(r,dict) or set(r)!=FIELDS or r['phase'] not in PHASES:
            raise ValueError('Invalid resource sample')
        if (not integer(r['monotonicUs']) or r['status'] not in ('ok','unavailable')
            or r['thermal'] not in ('nominal','fair','serious','critical','unknown')
            or r['power'] not in ('ac','battery','unknown')):
            raise ValueError('Invalid resource observation')
        for k in ('cpuUs','rssBytes','footprintBytes'):
            if not (integer(r[k]) if r['status']=='ok' else r[k] is None):
                raise ValueError('Missing or invalid resource value')
        if previous and (r['monotonicUs'] <= previous['monotonicUs'] or PHASES.index(r['phase']) < PHASES.index(previous['phase'])):
            raise ValueError('Clock or phase moved backwards')
        if r['cpuUs'] is not None:
            if last_cpu is not None and r['cpuUs'] < last_cpu: raise ValueError('CPU counter reset')
            last_cpu=r['cpuUs']
        phase=groups.setdefault(r['phase'],dict(samples=0,unavailable=0,firstUs=r['monotonicUs'],lastUs=0,
            rss=[],footprint=[],cpuIntervals=[]))
        phase['samples']+=1;phase['lastUs']=r['monotonicUs'];phase['unavailable']+=r['status']!='ok'
        thermal[r['thermal']]+=1;power[r['power']]+=1
        if r['status']=='ok':
            phase['rss'].append(r['rssBytes']);phase['footprint'].append(r['footprintBytes'])
            if previous and previous['phase']==r['phase'] and previous['status']=='ok':
                phase['cpuIntervals'].append((r['cpuUs']-previous['cpuUs'],r['monotonicUs']-previous['monotonicUs']))
        previous=r
    phases={}
    for name,p in groups.items():
        pairs=p['cpuIntervals'];elapsed=sum(dt for cpu,dt in pairs)
        memory=lambda values:dict(first=values[0] if values else None,last=values[-1] if values else None,
                                  peak=max(values) if values else None,samples=len(values))
        phases[name]=dict(samples=p['samples'],unavailableSamples=p['unavailable'],
            sampledWindowUs=p['lastUs']-p['firstUs'],
            cpuOneCorePercent=dict(intervals=len(pairs),coveredUs=elapsed,
                weightedMean=100*sum(cpu for cpu,dt in pairs)/elapsed if elapsed else None,
                peak=max(100*cpu/dt for cpu,dt in pairs) if pairs else None),
            rssBytes=memory(p['rss']),footprintBytes=memory(p['footprint']))
    return dict(workload=workload,outcome=trial['outcome'],engine=trial['engine'],decoder=trial['decoder'],sampleCount=len(rows),unavailableSamples=sum(p['unavailable'] for p in groups.values()),
                phases=phases,thermalCounts=dict(thermal),powerCounts=dict(power),temperatureCelsius=None,
                gpuBytes=None,mediaLedgerBytes=None,budgetAdmission=False,performanceBaseline=False)


def summarize_trials(trials):
    if not trials or len(trials)>100: raise ValueError('Invalid resource run')
    summaries=[summarize_series(t) for t in trials]
    first=trials[0]
    keys=('schemaVersion','runId','pid','buildMode','intervalMs','plannedAttempts')
    if (any(any(t[k]!=first[k] for k in keys) or t.get('workload','playback')!=first.get('workload','playback') for t in trials)
        or sorted(t['attempt'] for t in trials)!=list(range(1,first['plannedAttempts']+1))):
        raise ValueError('Mixed or incomplete resource run')
    return dict(workload=first.get('workload','playback'),runId=first['runId'],plannedAttempts=first['plannedAttempts'],
                outcomes=dict(collections.Counter(t['outcome'] for t in trials)),trials=summaries,
                budgetAdmission=False,performanceBaseline=False)


def summarize_disposed_memory(trials):
    """Compare acknowledged-disposal endpoints; never diagnose a leak."""
    summarize_trials(trials)  # Exact identity, completeness and row validation.
    ordered=sorted(trials,key=lambda t:t['attempt'])
    endpoints=[]; previous=None; conditions=set(); eligible=len(ordered)>=2
    for t in ordered:
        rows=t['samples']
        if rows:
            if previous is not None and rows[0]['monotonicUs']<=previous:
                raise ValueError('Overlapping resource trials')
            previous=rows[-1]['monotonicUs']
        conditions.update((r['power'],r['thermal']) for r in rows)
        disposed=[r for r in rows if r['phase']=='disposed']
        end=disposed[-1] if disposed else None
        window=disposed[-1]['monotonicUs']-disposed[0]['monotonicUs'] if disposed else None
        available=end is not None and end['status']=='ok'
        endpoints.append(dict(attempt=t['attempt'],outcome=t['outcome'],
            monotonicUs=end['monotonicUs'] if end else None,
            sampledWindowUs=window, samples=len(disposed),
            rssBytes=end['rssBytes'] if available else None,
            footprintBytes=end['footprintBytes'] if available else None))
        eligible &= t['outcome']=='passed' and available and len(disposed)>=2 and window>=1000000
    eligible &= len(conditions)==1 and all('unknown' not in pair for pair in conditions)
    first,last=endpoints[0],endpoints[-1]
    return dict(workload=ordered[0].get('workload','playback'),endpoints=endpoints,conditionsStableAndKnown=len(conditions)==1 and all('unknown' not in pair for pair in conditions),
        elapsedUs=last['monotonicUs']-first['monotonicUs'] if eligible else None,
        deltaBytes=dict(rss=last['rssBytes']-first['rssBytes'],
                        footprint=last['footprintBytes']-first['footprintBytes']) if eligible else None,
        leakVerdict=None,performanceBaseline=False,budgetAdmission=False)


def summarize_endurance(trials):
    """Qualify the fixed 100-cycle observation, not continuous playback or leaks."""
    summary = summarize_trials(trials)
    summarize_disposed_memory(trials)  # Also reject overlapping trial clocks.
    if any(t['schemaVersion'] != 2 or t['plannedAttempts'] != 100 or
           t['buildMode'] != 'profile' or t['workload'] != 'playback' for t in trials):
        raise ValueError('Expected 100 profile playback cycles')
    ordered = sorted(trials, key=lambda t: t['attempt'])
    complete = summary['outcomes'] == {'passed': 100}
    for trial in ordered:
        if trial['outcome'] != 'passed':
            continue
        rows = trial['samples']
        starts = {phase: next((r['monotonicUs'] for r in rows if r['phase'] == phase), None)
                  for phase in PHASES}
        if (None in starts.values() or trial['engine'] == 'unknown' or
                trial['decoder'] == 'unknown'):
            raise ValueError('Passed endurance cycle lacks playback/phase evidence')
        complete &= (starts['opening'] - starts['idle'] >= 2000000 and
                     rows[-1]['monotonicUs'] - starts['disposed'] >= 2000000 and
                     all(r['status'] == 'ok' for r in rows))
    observed = [r for t in ordered for r in t['samples']]
    span = observed[-1]['monotonicUs'] - observed[0]['monotonicUs'] if observed else None
    complete &= span is not None and span >= 600000000
    return dict(plannedAttempts=100, outcomes=summary['outcomes'], observedSpanUs=span,
                minimumObservationUs=600000000, protocolCompleted=bool(complete),
                continuousPlayback=False, leakVerdict=None,
                performanceBaseline=False, budgetAdmission=False)


def main():
    try:
        if len(sys.argv)!=2: raise ValueError('Invalid arguments')
        rows=[]
        with Path(sys.argv[1]).open('rb') as f:
            while line:=f.readline(131073):
                if len(line)>131072 or len(rows)>=100: raise ValueError('Input limit')
                rows.append(json.loads(line,object_pairs_hook=unique_object,parse_constant=reject_constant))
        result=summarize_trials(rows)
    except (OSError,ValueError,TypeError,KeyError):
        print('Invalid or incomplete resource observations.',file=sys.stderr);return 2
    print(json.dumps(result,indent=2));return 0

if __name__=='__main__':sys.exit(main())
