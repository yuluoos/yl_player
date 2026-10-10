"""Correlate bounded test-only display timing; never infer physical output."""
import collections
import math


def diagnose_timing(rows):
    def require(ok, message):
        if not ok:raise ValueError(message)
    def number(value):return type(value) in (int,float) and math.isfinite(value)
    kinds=('tickGap','tickWork','mainQueue','producerGap')
    metrics=('tickCalls','probeSent','probeCompleted','probeCancelled','probeSkipped','total')
    seen={};drops={};drop_phases={};previous=None;first=None;truncated=False
    require(bool(rows),'Missing timing rows')
    for row in rows:
        d=row.get('timingDiagnostics',{})
        require(d.get('enabled') is True,'Timing probe absent/disabled')
        require(type(d.get('stopped')) is bool and type(d.get('probePending')) is bool,'Invalid timing state')
        require(all(type(d.get(k)) is int and d[k]>=0 for k in metrics),'Invalid timing counters')
        require(d['probeSent']==d['probeCompleted']+d['probeCancelled']+int(d['probePending']),'Probe accounting mismatch')
        require(not d['stopped'] or not d['probePending'],'Stopped probe still pending')
        counts=d.get('counts',{});events=d.get('events',[]);maxima=d.get('maxima',{})
        require(set(maxima)==set(kinds) and all(number(v) and v>=0 for v in maxima.values()),'Invalid timing maxima')
        require(set(counts)==set(kinds) and all(type(v) is int and v>=0 for v in counts.values()),'Invalid timing kinds')
        require(sum(counts.values())==d['total'],'Timing total mismatch')
        require(counts['mainQueue']<=d['probeCompleted'] and counts['tickWork']<=d['tickCalls'] and counts['tickGap']<=max(0,d['tickCalls']-1),'Timing counts exceed observations')
        require(type(events) is list and len(events)==min(32,d['total']),'Missing/bounded timing history')
        require([e.get('sequence') for e in events]==list(range(max(1,d['total']-31),d['total']+1)),'Noncontiguous timing history')
        local=collections.Counter();last_end=-math.inf
        for event in events:
            seq=event['sequence'];kind=event.get('kind');start=event.get('start');end=event.get('end');seconds=event.get('seconds')
            require(kind in kinds and all(number(v) for v in (start,end,seconds)),'Invalid timing event')
            require(0<=start<=end<=row['uptime'] and end>=last_end,'Nonmonotonic timing event')
            require(math.isclose(seconds,end-start,abs_tol=1e-8) and seconds>=(.1 if kind=='producerGap' else .03),'Invalid timing duration')
            require(maxima[kind]+1e-8>=seconds,'Timing maximum below observed event')
            require(seq not in seen or seen[seq]==event,'Changed timing event')
            seen[seq]=event;local[kind]+=1;last_end=end
            if first is None:first=seq
        require(all(local[k]<=counts[k] for k in kinds),'Timing history exceeds totals')
        if events and events[0]['sequence']>1:truncated=True
        if previous:
            require(all(d[k]>=previous[k] for k in metrics) and all(counts[k]>=previous['counts'][k] for k in kinds),'Timing counters moved backward')
            require(all(maxima[k]>=previous['maxima'][k] for k in kinds),'Timing maxima moved backward')
            if previous['stopped']:require(d==previous,'Timing mutated after stop')
            if d['total']-previous['total']<=32:
                added=collections.Counter(e['kind'] for e in events if e['sequence']>previous['total'])
                require(all(counts[k]-previous['counts'][k]==added[k] for k in kinds),'Timing increment mismatch')
        previous=d
        for event in row.get('dropDiagnostics',{}).get('events',[]):
            key=event['total'];require(key not in drops or drops[key]==event,'Changed drop event');drops[key]=event;drop_phases.setdefault(key,row['phase'])
    correlations=[]
    for key,event in sorted(drops.items()):
        start=event.get('previousTickUptime');end=event['uptime']
        matches=[] if start is None else [seq for seq,timing in sorted(seen.items()) if timing['start']<=end and timing['end']>=start]
        correlations.append(dict(dropTotal=key,reason=event['reason'],firstObservedPhase=drop_phases[key],timingSequences=matches))
    return dict(counts=previous['counts'],maxima=previous['maxima'],events=[e for _,e in sorted(seen.items())],correlations=correlations,
                firstRetainedSequence=first,historyTruncated=truncated,rootCauseProven=False,
                diagnosticOnly=True,productionAdmission=False)
