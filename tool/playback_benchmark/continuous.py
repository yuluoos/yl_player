"""Single-session, 20-minute synthetic AVC continuity observation, not an SLO."""
from resources import summarize_series, integer

COMMON={'schemaVersion','runId','pid','sequence','kind'}
TICK={'sessionId','positionUs','status','failure','engine','decoder','audioSelected','videoPresent','resource'}
RESULT={'outcome','cleaned','errorType','disposedSamples'}
PROTOCOL=dict(id='continuous-avc-v2',plannedAttempts=1,minimumPlaybackSeconds=1200,
    sampleIntervalMs=5000,maximumSampleGapMs=7500,minimumProgressRatio=0.90,
    maximumProgressRatio=1.10,maximumCumulativeDriftSeconds=5,maximumTicks=246,
    testTimeoutSeconds=1320,commandTimeoutSeconds=1500,continuousPlayback=True,
    createCalls=1,loadCalls=1,playCalls=1,seekCalls=0,pauseCalls=0,reloads=0,
    fixtureSeconds=1260,audioContent='silent AAC; no audible-output validation',fixture='owned synthetic AVC/AAC 320x180 24fps',
    cacheState='os-cache-uncontrolled',networkProfile='local-file',
    profiler='Flutter profile default; no runtime intervention',timeline='Flutter profile default; no runtime intervention',
    displayAssertion='owned caffeinate -d -i -u -t 1500; no window-focus guarantee',
    stackLogging=False,forcedGC=False,physicalOutput='not_verified',
    performanceBaseline=False,budgetAdmission=False)


def summarize_continuous(rows,run_id):
    if not isinstance(rows,list) or len(rows)>247:raise ValueError('Invalid record count')
    ticks=[];terminal=None;pid=None
    for i,r in enumerate(rows):
        if not isinstance(r,dict) or r.get('kind') not in ('tick','result'):raise ValueError('Invalid record')
        if set(r)!=COMMON | (TICK if r['kind']=='tick' else RESULT):raise ValueError('Invalid fields')
        if (type(r['schemaVersion']) is not int or r['schemaVersion']!=1 or r['runId']!=run_id or
            not integer(r['pid'],1) or not integer(r['sequence']) or r['sequence']!=i or terminal is not None):
            raise ValueError('Invalid identity/order')
        if pid is not None and pid!=r['pid']:raise ValueError('Mixed process')
        pid=r['pid']
        if r['kind']=='result':
            if r['outcome'] not in ('passed','failed','timeout') or type(r['cleaned']) is not bool or (r['errorType'] is not None and not isinstance(r['errorType'],str)):
                raise ValueError('Invalid outcome')
            terminal=r
        else:
            if (not isinstance(r['sessionId'],str) or not r['sessionId'] or len(r['sessionId'])>128 or
                not integer(r['positionUs']) or any(type(r[k]) is not bool for k in ('failure','audioSelected','videoPresent')) or
                r['status'] not in ('idle','loading','ready','playing','paused','buffering','completed','failed')):
                raise ValueError('Invalid playback observation')
            ticks.append(r)
    outcome=terminal['outcome'] if terminal else 'unobserved'
    # The existing resource validator preserves missing numeric values and
    # actual-time CPU weighting. Schema 3 explicitly freezes a distinct cadence.
    summary=summarize_series(dict(schemaVersion=3,workload='continuous-playback',runId=run_id,
        attempt=1,plannedAttempts=1,pid=pid or 1,buildMode='profile',intervalMs=5000,
        engine=ticks[0]['engine'] if ticks else 'unknown',decoder=ticks[0]['decoder'] if ticks else 'unknown',
        outcome=outcome if outcome!='unobserved' else 'failed',samples=[r['resource'] for r in ticks]))
    disposed=None
    if terminal:
        disposed=summarize_series(dict(schemaVersion=3,workload='continuous-playback',runId=run_id,
            attempt=1,plannedAttempts=1,pid=pid,buildMode='profile',intervalMs=5000,engine='unknown',decoder='unknown',
            outcome='failed',samples=terminal['disposedSamples']))
    # Disposal is a phase observation, not another playback attempt.
    if disposed is not None:disposed.pop('outcome')
    reasons=[]
    if (not disposed or disposed['sampleCount']!=2 or disposed['unavailableSamples'] or
        set(disposed['phases'])!={'disposed'} or disposed['phases']['disposed']['sampledWindowUs']<2000000):
        reasons.append('disposed-observation-incomplete')
    if ticks and terminal and terminal['disposedSamples'] and terminal['disposedSamples'][0]['monotonicUs']<=ticks[-1]['resource']['monotonicUs']:
        raise ValueError('Disposal clock before playback')
    if not terminal or outcome!='passed' or not terminal['cleaned'] or terminal['errorType'] is not None:reasons.append('outcome-or-cleanup-unconfirmed')
    wall=ticks[-1]['resource']['monotonicUs']-ticks[0]['resource']['monotonicUs'] if ticks else None
    progress=ticks[-1]['positionUs']-ticks[0]['positionUs'] if ticks else None
    if wall is None or wall<1200000000 or len(ticks)<161:reasons.append('duration-or-coverage-incomplete')
    if summary['unavailableSamples']:reasons.append('resource-unavailable')
    if ticks:
        first=ticks[0]
        for r in ticks:
            if (r['sessionId']!=first['sessionId'] or r['engine']!=first['engine'] or r['decoder']!=first['decoder'] or
                r['engine']=='unknown' or r['decoder']=='unknown' or r['status']!='playing' or r['failure'] or
                not r['audioSelected'] or not r['videoPresent'] or r['resource']['phase']!='playing'):
                reasons.append('playback-state-invalid');break
        for a,b in zip(ticks,ticks[1:]):
            dt=b['resource']['monotonicUs']-a['resource']['monotonicUs'];dp=b['positionUs']-a['positionUs']
            if dt>7500000 or not .90*dt<=dp<=1.10*dt:
                reasons.append('progress-or-sampling-gap');break
        if abs(progress-wall)>5000000:reasons.append('cumulative-drift')
    return dict(summary,plannedAttempts=1,observedTicks=len(ticks),outcome=outcome,
        playbackWallUs=wall,mediaProgressUs=progress,complete=not reasons,reasons=reasons,
        disposed=disposed,cleaned=terminal['cleaned'] if terminal else None,physicalOutput='not_verified',leakVerdict=None)
