from pathlib import Path
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();s=s.replace("getattr(args, 'auto_scenario', 'normal') not in ('caps-during-preparation', 'fixed-during-preparation')", "getattr(args, 'auto_scenario', 'normal') not in ('caps-during-preparation', 'fixed-during-preparation', 'pause-during-preparation', 'seek-during-preparation')",1)
at='def summarize_public_race(rows, frames, policy):\n'
t='''def summarize_public_transport(rows, frames, policy):
    def require(value):
        if not value: raise ValueError('incomplete public transport race evidence')
    def finite(v):
        return type(v) in (int,float) and math.isfinite(v) and v >= 0
    require(isinstance(rows,list) and len(rows)>=4 and isinstance(frames,list) and isinstance(policy,dict))
    require(all(isinstance(r,dict) and finite(r.get('elapsed')) and finite(r.get('position')) for r in rows))
    require(all(a['elapsed']<b['elapsed'] for a,b in zip(rows,rows[1:])))
    scenario=rows[0].get('autoScenario');session=rows[0].get('sessionId')
    require(scenario in ('pause-during-preparation','seek-during-preparation') and isinstance(session,str) and bool(session))
    events=rows[-1].get('automaticEvents')
    require(isinstance(events,list) and 1<=len(events)<=2 and all(isinstance(e,dict) for e in events))
    e=events[0]
    require(e.get('attempt')==1 and e.get('outcome')=='preparationFailed' and e.get('warmupOutcome')=='cancelled' and e.get('warmupStage')=='waitingReady')
    require(all(e.get(k) is True for k in ('publicCommandReady','publicCommandApplied','warmupDetached','warmupOldItemRetained')))
    require(all(e.get(k) is False for k in ('publicCommandManuallyInvalidated','publicCommandItemChanged','warmupReusesPrerolledItem')))
    require(e.get('publicCommandSessionId')==session and e.get('freshPreparedItemInstalled') is not True)
    before=e.get('publicCommandIntentBefore');after=e.get('publicCommandIntentAfter')
    require(type(before) is int and type(after) is int and 0<=before<after<2**64 and after==before+1)
    times=('due','elapsed','warmupStartedElapsed','publicCommandStartedElapsed','publicCommandCompletedElapsed','elapsedAfter')
    require(all(finite(e.get(k)) for k in times+('warmupDeadlineElapsed','warmupCompletedElapsed','publicCommandPositionBefore')))
    require(all(e[a]<=e[b] for a,b in zip(times,times[1:])))
    deadline=min(e['warmupStartedElapsed']+2,e['due']+5)
    require(math.isclose(e['warmupDeadlineElapsed'],deadline,rel_tol=0,abs_tol=1e-6))
    require(e['publicCommandStartedElapsed']<=e['warmupCompletedElapsed']<=min(deadline,e['elapsedAfter']) and e['publicCommandCompletedElapsed']<=deadline)
    require(e['elapsedAfter']<=rows[-1]['elapsed'])
    previous=0
    for r in rows:
        budget=r.get('automaticAttempts');history=r.get('automaticEvents')
        require(type(budget) is int and previous<=budget<=2 and isinstance(history,list) and history==events[:len(history)] and len(history)<=budget)
        previous=budget
        require(r.get('publicPolicyRace') is True and r.get('publicPolicyCycle') is False and r.get('autoScenario')==scenario and r.get('sessionId')==session and r.get('hostFailureCount')==0 and r.get('hostStatus') in ('loading','ready','playing','paused','buffering','completed'))
        require(all(k in r and r[k]==v for k,v in dict(acceptedMaximumWidth=None,acceptedMaximumHeight=None,acceptedMaximumBitrate=None,fixedTrackId=None,peak=0,maximumWidth=0,maximumHeight=0).items()))
        if r['elapsed']>=e['elapsedAfter']:require(type(r.get('publicIntentRevision')) is int and r['publicIntentRevision']>=after)
    require(policy.get('triggerExercised') is True and policy.get('attempts')==previous==policy.get('reservations') and policy.get('tickets')==len(events))
    for later in events[1:]:
        require(later.get('attempt')==2 and later.get('outcome') in ('cancelled','preparationFailed') and later.get('freshPreparedItemInstalled') is not True and later.get('itemChanged') is not True)
    require(all(isinstance(f,dict) and finite(f.get('elapsed')) and finite(f.get('position')) and type(f.get('frames')) is int and f['frames']>=0 and type(f.get('width')) is int for f in frames))
    require(all(a['elapsed']<b['elapsed'] for a,b in zip(frames,frames[1:])))
    start=e['publicCommandCompletedElapsed']
    if scenario=='pause-during-preparation':
        resume=rows[-1].get('publicResume');require(isinstance(resume,dict))
        require(resume.get('applied') is True and resume.get('itemUnchanged') is True and resume.get('oldTicketAuthorized') is False and resume.get('sessionId')==session)
        require(all(finite(resume.get(k)) for k in ('startedElapsed','completedElapsed','pausedElapsed')))
        require(resume['pausedElapsed']>=e['publicCommandStartedElapsed'] and resume['startedElapsed']-resume['pausedElapsed']>=2 and start<=resume['startedElapsed']<=resume['completedElapsed']<=rows[-1]['elapsed'])
        require(finite(e.get('publicPausePosition')))
        paused=[r for r in rows if start<=r['elapsed']<resume['startedElapsed']]
        require(len(paused)>=3 and all(r.get('publicPlaybackIntent') is False and r.get('rate')==0 and r.get('hostStatus')=='paused' and abs(r['position']-e['publicPausePosition'])<=.05 for r in paused))
        start=resume['completedElapsed']
        require(any(r.get('publicPlaybackIntent') is True and r.get('rate',0)>0 for r in rows if r['elapsed']>=start))
    else:
        target=e.get('publicSeekTargetMs')
        require(type(target) is int and target>=0 and abs(target-(int(e['publicCommandPositionBefore']*1000)+1000))<=1)
    published=[f for f in frames if f['elapsed']>=start and f['frames']>0]
    require(len(published)>=3 and all(f['width'] in (320,640) for f in published) and any(f['width']==640 for f in published))
    if scenario=='seek-during-preparation':require(all(f['position']>=target/1000-.05 for f in published))
    require(published[-1]['position']>published[0]['position']+.1)
    return dict(scenario=scenario,oldCandidateRejected=True,sameItem=True,sameSession=True,
                sourceAttempts=previous,publishedFrames=sum(f['frames'] for f in published),
                capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False)


'''
assert at in s;s=s.replace(at,t+at)
s=s.replace('''    """Reject missing races: a naturally issued ticket and real command must win."""
''','''    """Reject missing races: a naturally issued ticket and real command must win."""
    if isinstance(rows,list) and rows and isinstance(rows[0],dict) and rows[0].get('autoScenario') in ('pause-during-preparation','seek-during-preparation'):
        return summarize_public_transport(rows,frames,policy)
''',1);p.write_text(s)
