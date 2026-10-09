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
