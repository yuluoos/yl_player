from pathlib import Path
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();at=s.index('\ndef summarize_production_command')
s=s[:at]+'''
def production_sessions(rows):
    """A public Load is the only permitted source-budget/session boundary."""
    def require(v):
        if not v: raise ValueError('invalid production session boundary')
    require(bool(rows))
    command=rows[-1].get('productionCommand', 'none')
    sessions=list(dict.fromkeys(r.get('sessionId') for r in rows))
    require(all(isinstance(v,str) and v for v in sessions))
    if command!='load-prepared':
        require(len(sessions)==1); return sessions
    e=rows[-1].get('productionCommandEvents',{})
    require(all(r.get('productionCommand')==command and r.get('productionRecovery') is True for r in rows))
    require(len(sessions)==2 and sessions==[e.get('sessionId'),e.get('newSessionId')])
    boundary=next(i for i,r in enumerate(rows) if r['sessionId']==sessions[1])
    require(all(r['sessionId']==sessions[1] for r in rows[boundary:]))
    require(rows[boundary]['elapsed']>=e['commandStarted'])
    require(all(r['sessionId']==sessions[1] for r in rows if r['elapsed']>=e['commandCompleted']))
    return sessions


def summarize_production_race(rows, frames, policy):
    def require(v):
        if not v: raise ValueError('invalid prepared production race evidence')
    def finite(v): return type(v) in (int,float) and math.isfinite(v) and v>=0
    require(bool(rows) and bool(frames) and isinstance(policy,dict))
    e=rows[-1].get('productionCommandEvents');require(isinstance(e,dict) and not e.get('failed',False))
    command=e.get('scenario');require(command in ('pause-prepared','seek-prepared','load-prepared'))
    require(all(r.get('productionCommand')==command for r in rows))
    sessions=production_sessions(rows)
    require(e.get('sessionId')==sessions[0] and e.get('attemptsAtCommand')==1 and e.get('tokenCancelled') is True)
    times=[e.get(k) for k in ('candidatePrepared','commandStarted','commandCompleted','released')]
    require(all(finite(t) for t in times) and times==sorted(times))
    old=e.get('oldEvents');require(isinstance(old,list) and len(old)==1)
    first=old[0];require(first.get('attempt')==1 and first.get('outcome')=='cancelled' and first.get('itemChanged') is not True)
    require(all(finite(first.get(k)) for k in ('elapsed','elapsedAfter','preparationDeadline')))
    require(first['elapsed']<=times[0]<=times[1]<=first['elapsedAfter']<=times[2]<=times[3]<first['preparationDeadline'])
    require(first['preparationDeadline']==first['elapsed']+2)
    if command=='load-prepared':
        require(e.get('itemUnchanged') is False and len(sessions)==2)
        require(rows[-1].get('automaticAttempts')==0 and rows[-1].get('automaticEvents')==[])
        require(isinstance(policy.get('sessions'),dict) and set(policy['sessions'])==set(sessions))
        before,after=(policy['sessions'][v] for v in sessions)
        require(before.get('attempts')==before.get('reservations')==before.get('tickets')==1)
        require(after.get('attempts')==after.get('reservations')==after.get('tickets')==0)
    else:
        require(e.get('itemUnchanged') is True and len(sessions)==1)
        events=rows[-1].get('automaticEvents')
        require(isinstance(events,list) and len(events)==2 and events[0]==first)
        require(events[1].get('attempt')==2 and events[1].get('outcome')=='installed' and events[1]['elapsed']>times[3])
        require(rows[-1].get('automaticAttempts')==2 and policy.get('attempts')==policy.get('reservations')==policy.get('tickets')==2)
        require([a.get('attempt') for a in policy.get('ticketAuthorities',[])]==[1,2])
    start=times[2]
    if command=='pause-prepared':
        require(e.get('pauseAcknowledged') is True and e.get('resumed') is True and e.get('itemUnchangedBeforeResume') is True)
        require(all(finite(e.get(k)) for k in ('resumeCompleted','pausePosition','beforeResumePosition')))
        require(e['resumeCompleted']-start>=2 and abs(e['pausePosition']-e['beforeResumePosition'])<=.05 and e.get('beforeResumeAttempts')==1)
        paused=[r for r in rows if start+.1<=r['elapsed']<e['resumeCompleted']-.1]
        require(len(paused)>=3 and all(r.get('publicPlaybackIntent') is False and r.get('rate')==0 and r.get('hostStatus')=='paused' and abs(r['position']-e['pausePosition'])<=.05 and r.get('automaticAttempts')==1 and r.get('automaticEvents')==old for r in paused))
        require(events[1]['elapsed']>e['resumeCompleted']);start=e['resumeCompleted']
    published=[f for f in frames if f['elapsed']>=start and f.get('frames',0)>0]
    require(len(published)>=2 and any(f.get('width')==640 for f in published))
    if command in ('seek-prepared','load-prepared'):
        target=e.get('targetMs');require(type(target) is int and finite(e.get('positionBefore')) and abs(target-(int(e['positionBefore']*1000)+1000))<=1)
        for f in published:
            pts=f.get('framePresentationTimes');require(isinstance(pts,list) and len(pts)==f['frames'] and all(finite(v) and v>=target/1000-.05 for v in pts))
            require(finite(f.get('position')) and f['position']>=target/1000-.05)
    require(published[-1]['position']>published[0]['position']+.1)
    return dict(scenario=command,oldCandidateRejected=True,newLoad=command=='load-prepared',
        secondAttemptInstalled=command!='load-prepared',publishedFrames=sum(f['frames'] for f in published),
        capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False)

''' + s[at:]
s=s.replace("('none', 'pause-resume')","('none', 'pause-resume', 'pause-prepared', 'seek-prepared', 'load-prepared')")
s=s.replace("    session = rows[0].get('sessionId')", "    sessions = production_sessions(rows)\n    session = rows[0].get('sessionId')",1)
s=s.replace("r.get('sessionId') == session and r.get('publicPolicyCycle')", "r.get('sessionId') in sessions and r.get('publicPolicyCycle')",1)
s=s.replace('triggerExercised=bool(installed), publicSessionUnchanged=True,','triggerExercised=bool(installed), publicSessionUnchanged=len(sessions)==1, newLoad=len(sessions)==2,')
old="""            previous = 0
            final = rows[-1].get('automaticEvents')
            require(isinstance(final, list) and len(final) <= 2)
            for row in rows:
                budget = row.get('automaticAttempts')
                require(type(budget) is int and previous <= budget <= 2)
                previous = budget
                events = row.get('automaticEvents')
                require(isinstance(events, list) and events == final[:len(events)] and len(events) <= budget)
"""
new="""            previous = 0
            load_race=rows[-1].get('productionCommand')=='load-prepared'
            sessions=production_sessions(rows) if load_race else None
            final = rows[-1].get('automaticEvents')
            require(isinstance(final, list) and len(final) <= 2)
            prior_session=None
            for row in rows:
                if load_race and row['sessionId']!=prior_session: previous=0
                prior_session=row.get('sessionId')
                budget = row.get('automaticAttempts')
                require(type(budget) is int and previous <= budget <= 2)
                previous = budget
                expected = rows[-1]['productionCommandEvents']['oldEvents'] if load_race and row['sessionId']==sessions[0] else final
                events = row.get('automaticEvents')
                require(isinstance(events, list) and events == expected[:len(events)] and len(events) <= budget)
"""
assert old in s;s=s.replace(old,new)
old="""            receipt['policyObservation'] = summarize_policy(read_rows(out/'policy-decisions.jsonl'),
                expected_attempts=rows[-1]['automaticAttempts'])
            validate_recovery_authority(rows,receipt['policyObservation'])"""
new="""            decisions=read_rows(out/'policy-decisions.jsonl')
            if production and getattr(args,'production_command','none')=='load-prepared':
                sessions=production_sessions(rows); summaries={}
                if any(d.get('sessionId') not in sessions for d in decisions): raise ValueError('unbound policy session')
                for index,session in enumerate(sessions):
                    selected=[r for r in rows if r['sessionId']==session]
                    selected=[dict(r) for r in selected]
                    if index==0:
                        selected[-1]['automaticEvents']=rows[-1]['productionCommandEvents']['oldEvents']
                        selected[-1]['automaticAttempts']=1
                    summaries[session]=summarize_policy([d for d in decisions if d['sessionId']==session],expected_attempts=selected[-1]['automaticAttempts'])
                    validate_recovery_authority(selected,summaries[session])
                receipt['policyObservation']={'sessions':summaries,'capabilityAccepted':False}
            else:
                receipt['policyObservation'] = summarize_policy(decisions, expected_attempts=rows[-1]['automaticAttempts'])
                validate_recovery_authority(rows,receipt['policyObservation'])"""
assert old in s;s=s.replace(old,new)
s=s.replace("            if command == 'pause-resume':", "            if command.endswith('-prepared'):\n                receipt['productionCommandObservation'] = summarize_production_race(rows, read_rows(out/'frame-samples.jsonl'), receipt.get('policyObservation'))\n            if command == 'pause-resume':")
p.write_text(s)
