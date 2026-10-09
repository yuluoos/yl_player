"""Validate internal decoded A/V continuity, never physical presentation."""
import math


def validate(rows, minimum_seconds):
    def require(ok, message):
        if not ok: raise ValueError(message)
    require(minimum_seconds in (30,1200), 'Unknown protocol duration')
    require(bool(rows) and len(rows)<=250, 'Missing/oversized observations')
    require(len({(r['pid'],r['generation']) for r in rows})==1, 'Changed identity')
    require(all(isinstance(r['uptime'],(int,float)) and math.isfinite(r['uptime']) for r in rows), 'Invalid clock')
    require(all(b['uptime']>a['uptime'] for a,b in zip(rows,rows[1:])), 'Nonmonotonic clock')
    require([r['phase'] for r in rows[-2:]]==['disposed','disposedLater'], 'Missing disposal')
    ticks=rows[:-2]
    require(len(ticks)>=7 and all(r['phase']=='playing' for r in ticks), 'Missing playing observations')
    require(all(not r['failures'] and r['rendererCount']==1 and r['orderErrors']==0 and
                0<=r['maxLagUs']<=100000 for r in rows), 'Sticky error or frame violation')
    for r in ticks:
        require(r['candidate'] is True and r['nativePlaying'] is True and r['pending'] is True, 'Stopped/fallback output')
        modes=r['modes']
        require(all(type(modes[k]) is int and modes[k]>=0 for k in ('renderedSubmissions','renderedCallbacks','playedSubmissions','playedCallbacks')), 'Invalid mode counters')
        require(modes['renderedSubmissions']>0 and modes['playedSubmissions']==0 and modes['playedCallbacks']==0 and
                0<modes['renderedCallbacks']<=modes['renderedSubmissions'], 'Actual output used legacy mode before EOF')
        require(all(type(r[k]) is int and r[k]>=0 for k in ('audioUs','positionUs','videoPTS','videoFrames','published','ledgerBytes')), 'Missing/invalid clock or counters')
        require(abs(r['audioUs']-r['positionUs'])<=100000, 'Audio/media clock mismatch')
        require(0<=r['positionUs']-r['videoPTS']<=100000, 'Stale or future video frame')
        require(r['dropped']==0 and type(r['frameAgeUs']) is int and 0<=r['frameAgeUs']<=100000, 'Dropped or stale selected frame')
        require(type(r['directPublished']) is int and 0<=r['directPublished']<=1 and
                r['directPublished']==ticks[0]['directPublished'] and
                r['published']==r['videoFrames']+r['directPublished'], 'Selected frame not published')
    for a,b in zip(ticks,ticks[1:]):
        dt=b['uptime']-a['uptime']
        require(dt<=7.5, 'Sampling gap')
        for k in ('audioUs','positionUs'):
            require(.90*dt*1e6<=b[k]-a[k]<=1.10*dt*1e6, 'Progress mismatch')
        require(b['videoFrames']>a['videoFrames'] and b['videoPTS']>a['videoPTS'], 'Video stalled')
        require(b['modes']['renderedSubmissions']>a['modes']['renderedSubmissions'] and
                b['modes']['renderedCallbacks']>a['modes']['renderedCallbacks'], 'Audio submission/callback stalled')
    duration=ticks[-1]['uptime']-ticks[0]['uptime']
    require(duration>=minimum_seconds, 'Short observation')
    drift=(ticks[-1]['audioUs']-ticks[0]['audioUs'])/1e6-duration
    require(abs(drift)<=5, 'Cumulative drift')
    require(all(r['ledgerBytes']==0 and r['pending'] is False and r['nativePlaying'] is False for r in rows[-2:]), 'Unreleased output')
    require(rows[-1]['uptime']-rows[-2]['uptime']>=2, 'Missing delayed disposal')
    return dict(durationSeconds=duration,ticks=len(ticks),audioClockDriftSeconds=drift,
        maximumSelectionLagUs=max(r['maxLagUs'] for r in rows),videoFrames=ticks[-1]['videoFrames'],
        physicalOutputVerified=False,productionAdmission=False,downstreamBoundProven=False)


def diagnose_drops(rows):
    """Describe bounded scheduler evidence even when the zero-drop gate fails."""
    reasons = ('lateArrival','durationLimit','enqueueTimeout','lateAfterCapacity','capacityEviction','catchUp')
    previous = dict.fromkeys(reasons, 0)
    events = {}
    def require(ok, message):
        if not ok: raise ValueError(message)
    require(bool(rows), 'Missing drop diagnostics')
    for row in rows:
        snapshot = row.get('dropDiagnostics', {})
        counts = snapshot.get('counts', {})
        require(set(counts) == set(reasons) and
                all(type(counts[k]) is int and counts[k] >= previous[k] for k in reasons), 'Invalid drop counters')
        require(type(snapshot.get('total')) is int and snapshot['total'] == row['dropped'] == sum(counts.values()), 'Inconsistent drop total')
        retained = snapshot.get('events')
        require(isinstance(retained, list) and len(retained) <= 16, 'Invalid drop event bound')
        require(bool(retained) == (snapshot['total'] > 0), 'Missing drop event')
        last_total = 0
        for event in retained:
            require(event['reason'] in reasons and type(event['count']) is int and event['count'] > 0 and
                    type(event['total']) is int and last_total < event['total'] <= snapshot['total'] and
                    event['count'] <= event['total'], 'Invalid drop event counters')
            require(event['generation'] == row['generation'] and
                    math.isfinite(event['uptime']) and event['uptime'] <= row['uptime'], 'Invalid drop event identity/clock')
            require(event['previousTickUptime'] is None or
                    (math.isfinite(event['previousTickUptime']) and event['previousTickUptime'] <= event['uptime']), 'Invalid previous tick')
            require(0 <= event['enqueueWaitSeconds'] and math.isfinite(event['enqueueWaitSeconds']), 'Invalid enqueue elapsed time')
            prior = events.get(event['total'])
            require(prior is None or prior == event, 'Changed retained drop event')
            events[event['total']] = event.copy(); last_total = event['total']
        if retained: require(last_total == snapshot['total'], 'Missing latest drop event')
        observed = dict.fromkeys(reasons, 0)
        for event in events.values(): observed[event['reason']] += event['count']
        require(all(observed[k] <= counts[k] for k in reasons), 'Event reason exceeds counter')
        if sum(observed.values()) == snapshot['total']:
            require(observed == counts, 'Event reasons disagree with counters')
        previous = counts.copy()
    described = []
    for event in events.values():
        value = event.copy()
        previous_tick = event['previousTickUptime']
        value['tickGapSeconds'] = None if previous_tick is None else event['uptime'] - previous_tick
        value['mediaAdvanceUs'] = None if event['positionUs'] is None or event['previousPositionUs'] is None else event['positionUs'] - event['previousPositionUs']
        described.append(value)
    return dict(counts=previous, events=described, diagnosticOnly=True,
                physicalOutputVerified=False, productionAdmission=False)


def diagnose_audio(rows):
    """Preserve failure-branch evidence independently of the passing-play gate."""
    kinds = ('playAttempt','playSucceeded','playFailed','configurationInvalidated','disposed','rendererFailure','startupFailure')
    previous = {}; events = {}
    def require(ok, message):
        if not ok: raise ValueError(message)
    require(bool(rows), 'Missing audio diagnostics')
    for row in rows:
        snapshot = row.get('audioDiagnostics', {})
        counts = snapshot.get('counts', {})
        require(set(counts).issubset(kinds) and all(type(v) is int and v >= 0 for v in counts.values()) and
                all(counts.get(k,0) >= previous.get(k,0) for k in kinds), 'Invalid audio counters')
        total = snapshot.get('total'); retained = snapshot.get('events')
        require(type(total) is int and total == sum(counts.values()) and
                isinstance(retained,list) and len(retained) == min(total,32), 'Invalid audio history bound')
        require([e['sequence'] for e in retained] == list(range(max(1,total-31),total+1)), 'Missing audio event sequence')
        for event in retained:
            seq = event['sequence']; kind = event['kind']
            require(kind in kinds and type(event['uptime']) in (int,float) and math.isfinite(event['uptime']) and
                    event['uptime'] <= row['uptime'], 'Invalid audio event identity/clock')
            require(seq not in events or events[seq] == event, 'Changed retained audio event')
            if kind in ('rendererFailure','startupFailure'):
                reason = event['reason']
                require(reason in ('configurationChanged','startFailed','unclassified'), 'Invalid audio failure reason')
                cause = {'configurationChanged':'configurationInvalidated','startFailed':'playFailed'}.get(reason)
                if cause:
                    # Retained history is a contiguous suffix; any omitted cause
                    # count is in the evicted prefix, before this failure.
                    later = sum(e['kind']==cause and e['sequence']>=seq for e in retained)
                    require(counts.get(cause,0)>later, 'Missing preceding audio failure cause')
            events[seq] = event.copy()
        observed = dict.fromkeys(kinds,0)
        for event in events.values(): observed[event['kind']] += 1
        require(all(observed[k] <= counts.get(k,0) for k in kinds), 'Audio event exceeds counter')
        ordered = sorted(events)
        require(all(events[b]['uptime'] >= events[a]['uptime'] for a,b in zip(ordered,ordered[1:])), 'Nonmonotonic audio event clock')
        previous = counts.copy()
    recorded = [events[k] for k in sorted(events)]
    return dict(counts=previous,events=recorded,
                configurationInvalidations=previous.get('configurationInvalidated',0),
                startFailures=previous.get('playFailed',0),startupFailures=previous.get('startupFailure',0),
                rendererFailureReasons=[e['reason'] for e in recorded if e['kind']=='rendererFailure'],
                diagnosticOnly=True,productionAdmission=False)
