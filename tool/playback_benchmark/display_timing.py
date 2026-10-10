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

def diagnose_cadence_boundary(rows):
    """Validate callback boundaries without equating sampled responsiveness with root cause."""
    def require(ok,message):
        if not ok:raise ValueError(message)
    def number(v):return type(v) in (int,float) and math.isfinite(v)
    kinds=('entryGap','refreshWork','bodyWork')
    seen={};drops={};previous=None;stopped=False
    require(bool(rows),'Missing cadence rows')
    for row in rows:
        timing=row.get('timingDiagnostics',{});d=timing.get('cadenceBoundary',{})
        require(timing.get('enabled') is True,'Cadence probe disabled')
        require(all(type(d.get(k)) is int and d[k]>=0 for k in ('calls','total')),'Invalid cadence counts')
        require(d['total']<=d['calls'],'Cadence events exceed calls')
        maxima=d.get('maxima',{});events=d.get('events',[])
        require(set(maxima)==set(kinds) and all(number(v) and v>=0 for v in maxima.values()),'Invalid cadence maxima')
        require(type(events) is list and len(events)==min(32,d['total']),'Invalid cadence history bound')
        require([e.get('sequence') for e in events]==list(range(max(1,d['total']-31),d['total']+1)),'Noncontiguous cadence history')
        last_end=-math.inf
        for e in events:
            seq=e['sequence'];prior=e.get('previousEntry');entry=e.get('entry');body=e.get('body');end=e.get('end')
            require(all(number(v) for v in (entry,body,end)) and 0<=entry<=body<=end<=row['uptime'] and end>=last_end,'Invalid cadence order')
            require(prior is None or number(prior) and 0<=prior<=entry,'Invalid previous cadence entry')
            for kind,want in zip(kinds,(entry-prior if prior is not None else 0,body-entry,end-body)):
                require(number(e.get(kind)) and math.isclose(e[kind],want,abs_tol=1e-8),'Invalid cadence duration')
                require(maxima[kind]+1e-8>=e[kind],'Cadence maximum below event')
            require(max(e[k] for k in kinds)>=.03,'Non-slow cadence event')
            responses=e.get('mainResponses',[])
            require(type(responses) is list and len(responses)<=16,'Unbounded main responses')
            last_delivery=-math.inf
            for response in responses:
                request=response.get('requested');delivery=response.get('delivered')
                require(number(request) and number(delivery) and 0<=request<=delivery<=end and delivery>last_delivery and delivery>=(prior if prior is not None else entry),'Invalid main response')
                last_delivery=delivery
            if 'runLoop' in e:
                loop=e['runLoop']
                require(type(loop) is list and len(loop)<=256 and type(e.get('runLoopHistoryTruncated')) is bool,'Invalid runloop history')
                last=-math.inf
                for point in loop:
                    stamp=point.get('uptime');activity=point.get('activity')
                    require(number(stamp) and 0<=stamp<=end and stamp>=last and type(activity) is int and activity in (1,2,4,32,64,128),'Invalid runloop event')
                    last=stamp
                since=prior if prior is not None else entry
                require(e['runLoopHistoryTruncated']==bool(loop and loop[0]['uptime']>since),'Incorrect runloop truncation marker')
            require(seq not in seen or seen[seq]==e,'Changed cadence event')
            seen[seq]=e;last_end=end
        if previous:
            require(all(d[k]>=previous[k] for k in ('calls','total')) and all(maxima[k]>=previous['maxima'][k] for k in kinds),'Cadence counters moved backward')
            if stopped:require(d==previous,'Cadence mutated after stop')
        previous=d;stopped=timing.get('stopped')
        for e in row.get('dropDiagnostics',{}).get('events',[]):
            require(e['total'] not in drops or drops[e['total']]==e,'Changed drop event')
            drops[e['total']]=e
    correlations=[]
    for key,e in sorted(drops.items()):
        start=e.get('previousTickUptime');end=e['uptime']
        matching=[seq for seq,t in sorted(seen.items()) if start is not None and (t['previousEntry'] if t['previousEntry'] is not None else t['entry'])<=end and t['end']>=start]
        correlations.append(dict(dropTotal=key,reason=e['reason'],cadenceSequences=matching))
    return dict(calls=previous['calls'],total=previous['total'],maxima=previous['maxima'],events=[v for _,v in sorted(seen.items())],
                correlations=correlations,rootCauseProven=False,diagnosticOnly=True,productionAdmission=False)
