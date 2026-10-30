"""Independent production v3 budget evidence; historical v1/v2 stay unchanged."""
import math


def require(value):
    if not value: raise ValueError('invalid v3 recovery renewal evidence')


def finite(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def validate_high_publication(row, frames):
    # Frame rows observe publication at the next pump sample, not its exact
    # uptime. Allow one 50ms boundary interval; interior continuity stays strict.
    start=row['highFrameStart']; end=start+row['highFrameSeconds']
    published=[f for f in frames if f.get('frames',0)>0 and start-.05<=f['elapsed']<=end+.05]
    core=[i for i,f in enumerate(published) if start<=f['elapsed']<=end]
    require(bool(core))
    first,last=core[0],core[-1]
    while first>0 and published[first-1].get('width')==640 and published[first-1].get('generation')==published[first].get('generation'):
        first-=1
    while last+1<len(published) and published[last+1].get('width')==640 and published[last+1].get('generation')==published[last].get('generation'):
        last+=1
    published=published[first:last+1]
    require(len(published)>=2 and sum(f['frames'] for f in published)>=row['highFrameCount'])
    require(abs(published[0]['elapsed']-start)<=.05 and abs(published[-1]['elapsed']-end)<=.05)
    require(all(type(f.get('frames')) is int and 1<=f['frames']<=2 and f.get('width')==640 and
                f.get('generation')==published[0].get('generation') and finite(f.get('position')) for f in published))
    require(all(0<b['elapsed']-a['elapsed']<=.5 and b['position']>a['position'] for a,b in zip(published,published[1:])))


def summarize_policy_v3(rows, *, expected_attempts, events, frames):
    reasons={'invalidSample','playbackIneligible','insufficientBuffer','nearEnd','nonMonotonic',
        'highOutput','highNotObserved','notLowOutput','noOverdue','backoff','ticketReady','inFlight',
        'budgetExhausted','windowStarted','countersReset','windowPending','noProgress',
        'insufficientRequests','insufficientBandwidth','firstQualifiedWindow','reserved','cooldown'}
    require(type(expected_attempts) is int and 0<=expected_attempts<=4)
    require(isinstance(rows,list) and 1<=len(rows)<=1000 and isinstance(events,list) and isinstance(frames,list))
    attempts=0; limit=2; last_reservation=None; last_installation=None; previous=-1
    revision=None; credential=None; anchor=None; qualified=0; pending=None; renewals=[]
    last_sample=None; last_authority_change=0
    counts={}; rates=[]; intent_samples=[]; credential_samples=[]; tickets=[]; reservations=[]
    session=rows[0].get('sessionId');require(isinstance(session,str) and bool(session))
    installs=[e for e in events if isinstance(e,dict) and e.get('outcome')=='installed']
    for row in rows:
        require(isinstance(row,dict) and row.get('sessionId')==session and row.get('reason') in reasons)
        elapsed=row.get('elapsed');reason=row['reason']
        require(finite(elapsed) and elapsed>previous);previous=elapsed
        for key in ('generation','width','overdue','qualifiedWindows','attempts','highFrameCount','intentRevision','credentialRevision'):
            require(type(row.get(key)) is int and row[key]>=0)
        require(row['intentRevision']<2**64 and row['credentialRevision']<2**64)
        require(revision is None or row['intentRevision']>=revision)
        require(credential is None or row['credentialRevision']>=credential)
        authority_changed=(revision is not None and row['intentRevision']!=revision) or (credential is not None and row['credentialRevision']!=credential)
        generation_changed=last_sample is not None and row['generation']!=last_sample['generation']
        if authority_changed or generation_changed:
            last_authority_change=elapsed;last_sample=None
        if (revision is not None and row['intentRevision']!=revision) or (credential is not None and row['credentialRevision']!=credential):
            anchor=None;qualified=0;pending=None
        if generation_changed:anchor=None;qualified=0;pending=None
        revision=row['intentRevision'];credential=row['credentialRevision']
        intent_samples.append(dict(elapsed=elapsed,intentRevision=revision))
        credential_samples.append(dict(elapsed=elapsed,credentialRevision=credential))
        require(type(row.get('budgetVersion')) is int and row['budgetVersion']==2)
        require(type(row.get('roundLimit')) is int and row['roundLimit'] in (2,4))
        require(row['qualifiedWindows']<=2 and attempts<=row['attempts']<=row['roundLimit'])
        for key in ('lastReservation','lastInstallation','highFrameStart'):
            require(key in row and (row[key] is None or finite(row[key]) and row[key]<=elapsed))
        require(finite(row.get('highFrameSeconds')))
        if row['highFrameCount']==0:
            require(row['highFrameStart'] is None and row['highFrameSeconds']==0)
        else:
            require(row['highFrameStart'] is not None and row['highFrameStart']+row['highFrameSeconds']<=elapsed+1e-6 and
                elapsed-(row['highFrameStart']+row['highFrameSeconds'])<=.5+1e-6)
        installation=row['lastInstallation']
        available=[e for e in installs if finite(e.get('elapsedAfter')) and e['elapsedAfter']<=elapsed]
        expected_installation=available[-1]['elapsedAfter'] if available else None
        require(installation==expected_installation)
        if installation!=last_installation:
            require(installation is not None and (last_installation is None or installation>last_installation))
            installed=available[-1]
            require(type(installed.get('attempt')) is int and installed['attempt']<=attempts and
                installed.get('itemChanged') is True and installed.get('credentialCommitAccepted') is True and
                any(t['attempt']==installed['attempt'] for t in tickets))
        last_installation=installation
        if row['roundLimit']!=limit:
            require(limit==2 and row['roundLimit']==4 and attempts==2 and reason=='highOutput' and
                installation is not None and row['highFrameCount']>=48 and row['highFrameSeconds']>=2 and
                row['highFrameStart'] is not None and row['highFrameStart']>=max(installation,last_authority_change))
            validate_high_publication(row,frames)
            renewals.append(dict(elapsed=elapsed,lastInstallation=installation,highFrameStart=row['highFrameStart'],
                highFrameCount=row['highFrameCount'],highFrameSeconds=row['highFrameSeconds']))
            limit=4
        for key in ('allowed','sawHigh'):require(type(row.get(key)) is bool)
        for key in ('bytes','requests'):require(type(row.get(key)) is int)
        for key in ('position','remaining','bufferAhead','transfer'):
            require(key in row and (row[key] is None or type(row[key]) in (int,float) and math.isfinite(row[key])))
        eligible=(row['allowed'] and all(finite(row[k]) for k in ('position','transfer')) and row['bytes']>=0 and row['requests']>=0 and
            row['bufferAhead'] is not None and row['bufferAhead']>=5 and row['remaining'] is not None and row['remaining']>=20)
        rejection=('playbackIneligible' if not row['allowed'] else
            'insufficientBuffer' if row['bufferAhead'] is not None and row['bufferAhead']<5 else
            'nearEnd' if row['remaining'] is not None and row['remaining']<20 else 'invalidSample' if not eligible else None)
        if rejection:require(reason==rejection)
        elif last_sample is not None and row['position']<last_sample['position']:require(reason=='nonMonotonic')
        else:
            require(reason not in ('playbackIneligible','insufficientBuffer','nearEnd','invalidSample','nonMonotonic'))
            if reason=='highOutput':require(row['width']==640 and row['sawHigh'])
            elif reason=='highNotObserved':require(row['width']!=640 and not row['sawHigh'])
            elif reason=='notLowOutput':require(row['sawHigh'] and row['width'] not in (320,640))
            elif reason=='noOverdue':require(row['sawHigh'] and row['width']==320 and row['overdue']==0)
            elif reason!='nonMonotonic':require(row['sawHigh'] and row['width']==320 and row['overdue']>0)
        if reason=='highOutput' and attempts==2 and installation is not None and row['highFrameStart'] is not None and row['highFrameStart']>=installation and row['highFrameCount']>=48 and row['highFrameSeconds']>=2:
            require(limit==4)
        if reason=='countersReset':
            require(last_sample is not None and any(row[k]<last_sample[k] for k in ('bytes','transfer','requests')))
        elif eligible and reason not in ('nonMonotonic','highOutput','highNotObserved','notLowOutput','noOverdue') and last_sample is not None:
            require(all(row[k]>=last_sample[k] for k in ('bytes','transfer','requests')))
        bitrate=row.get('windowBitrate');requests=row.get('windowRequests');due=row.get('pendingDue')
        require((bitrate is None)==(requests is None))
        require(bitrate is None or finite(bitrate))
        require(requests is None or type(requests) is int and requests>=0)
        require(due is None or finite(due))
        completed=reason in ('noProgress','insufficientRequests','insufficientBandwidth','firstQualifiedWindow') or reason in ('reserved','cooldown') and bitrate is not None
        if completed:
            require(anchor is not None and row['generation']==anchor['generation'] and elapsed-anchor['elapsed']>=8)
            require(all(row[k]>=anchor[k] for k in ('bytes','transfer','requests')))
            duration=row['transfer']-anchor['transfer'];measured=(row['bytes']-anchor['bytes'])*8/duration if duration>0 else 0
            require(bitrate is not None and math.isclose(bitrate,measured,rel_tol=1e-9,abs_tol=1e-6) and requests==row['requests']-anchor['requests'])
            rates.append(bitrate)
            failure=('noProgress' if row['position']<=anchor['position'] else 'insufficientRequests' if requests<3 else 'insufficientBandwidth' if bitrate<955000 else None)
            if failure:require(reason==failure);qualified=0
            else:
                qualified=min(2,qualified+1)
                require(reason==('firstQualifiedWindow' if qualified==1 else 'cooldown' if last_reservation is not None and elapsed-last_reservation<30 else 'reserved'))
            anchor=row
        elif reason in ('windowStarted','countersReset'):
            require(bitrate is None);anchor=row;qualified=0
        elif reason in ('windowPending','cooldown','reserved'):
            require(anchor is not None and row['generation']==anchor['generation'] and elapsed-anchor['elapsed']<8 and bitrate is None)
            if reason=='windowPending':require(qualified<2)
            else:require(qualified==2)
        else:
            require(bitrate is None);anchor=None;qualified=0
        if reason=='cooldown':require(qualified==2 and last_reservation is not None and elapsed-last_reservation<30 and attempts<limit)
        if reason=='budgetExhausted':require(attempts==limit)
        if reason in ('windowStarted','countersReset','windowPending','firstQualifiedWindow','reserved'):require(attempts<limit)
        if reason=='reserved':
            require(qualified==2 and row['attempts']==attempts+1 and (last_reservation is None or elapsed-last_reservation>=30))
            require(due is not None and math.isclose(due-elapsed,.5 if row['attempts']==1 else 1,abs_tol=1e-6))
            last_reservation=elapsed;anchor=None;qualified=0
            pending=(row['attempts'],row['generation'],due,revision,credential)
            reservations.append(dict(attempt=row['attempts'],elapsed=elapsed))
        else:
            require(row['attempts']==attempts)
            if reason=='ticketReady':
                require(pending is not None and pending[0]==attempts and pending[1]==row['generation'] and elapsed>=pending[2] and pending[3:]==(revision,credential) and due is None)
                tickets.append(dict(attempt=attempts,elapsed=elapsed,intentRevision=revision,credentialRevision=credential));pending=None
            elif reason=='backoff':require(pending is not None and elapsed<pending[2] and due==pending[2])
            else:pending=None;require(due is None)
        require(row['lastReservation']==last_reservation and row['qualifiedWindows']==qualified)
        last_sample=None if rejection or reason=='nonMonotonic' else row
        attempts=row['attempts'];counts[reason]=counts.get(reason,0)+1
    require(attempts==expected_attempts)
    return dict(samples=len(rows),reasonCounts=counts,attempts=attempts,roundLimit=limit,renewals=len(renewals),
        renewalEvidence=renewals,reservationEvidence=reservations,reservations=len(reservations),tickets=len(tickets),
        triggerExercised=bool(tickets),intentSamples=intent_samples,credentialSamples=credential_samples,ticketAuthorities=tickets,
        windowBitrateMinimum=min(rates) if rates else None,windowBitrateMaximum=max(rates) if rates else None,capabilityAccepted=False)


def summarize_budget_renewal(rows, frames, decisions, policy):
    """Actual first-round exhaustion, renewed attempt three, and high-low-high."""
    from abr_accesslog import policy_trace_version, production_sessions
    require(policy_trace_version(rows)==3 and len(production_sessions(rows))==1)
    session=rows[0]['sessionId']
    require(all(r.get('productionRecovery') is True and r.get('captureDeviceKind')=='physical' and r.get('hostFailureCount')==0 for r in rows))
    require(all(d.get('sessionId')==session for d in decisions))
    require(policy['attempts']>=3 and policy['renewals']==1)
    events=rows[-1]['automaticEvents']
    second=[e for e in events if e.get('attempt')==2 and e.get('outcome')=='installed']
    third=[e for e in events if e.get('attempt')==3 and e.get('outcome')=='installed']
    require(len(second)==len(third)==1)
    second=second[0];third=third[0]
    for event in (second,third):require(event.get('itemChanged') is True and event.get('credentialCommitAccepted') is True and finite(event.get('elapsedAfter')))
    renewal=policy['renewalEvidence'][0]
    require(renewal['lastInstallation']==second['elapsedAfter'])
    reserved=next(v for v in policy['reservationEvidence'] if v['attempt']==3)
    require(second['elapsedAfter']<renewal['elapsed']<reserved['elapsed']<=third['elapsed']<=third['elapsedAfter'])
    published=[f for f in frames if f.get('frames',0)>0]
    high=next((f for f in published if second['elapsedAfter']<f['elapsed']<=renewal['elapsed'] and f.get('width')==640),None)
    require(high is not None)
    low=next((f for f in published if renewal['elapsed']<f['elapsed']<=reserved['elapsed'] and f.get('width')==320),None)
    require(low is not None and low.get('generation')==high.get('generation'))
    require(any(f['elapsed']>third['elapsedAfter'] and f.get('width')==640 for f in published))
    tail=[d for d in decisions if second['elapsedAfter']<=d['elapsed']<=third['elapsed']]
    require(bool(tail) and all(d.get('generation')==tail[0].get('generation') and d.get('intentRevision')==second['ticketIntentRevision'] and
        d.get('credentialRevision')==second['ticketCredentialRevision'] for d in tail))
    require(third['ticketIntentRevision']==second['ticketIntentRevision'] and third['ticketCredentialRevision']==second['ticketCredentialRevision'])
    return dict(secondInstallElapsed=second['elapsedAfter'],renewalElapsed=renewal['elapsed'],
        secondDownshiftElapsed=low['elapsed'],thirdInstallElapsed=third['elapsedAfter'],maximumAttempts=4,
        thirdReservationObserved=True,capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False)
