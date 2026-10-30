"""Strict repeated-downshift evidence; does not alter native recovery policy."""
import math


def summarize_budget_exhaustion(rows, frames, decisions):
    def require(value):
        if not value: raise ValueError('invalid repeated downshift budget evidence')
    def finite(v):
        try: return type(v) in (int, float) and math.isfinite(v) and v >= 0
        except OverflowError: return False
    require(isinstance(rows, list) and 2 <= len(rows) <= 1000)
    require(isinstance(frames, list) and 2 <= len(frames) <= 20000)
    require(isinstance(decisions, list) and 3 <= len(decisions) <= 1000)
    require(all(isinstance(v, dict) for v in rows+frames+decisions))
    session=rows[0].get('sessionId');require(isinstance(session,str) and bool(session))
    require(all(v.get('sessionId')==session and v.get('productionRecovery') is True and
        v.get('captureDeviceKind')=='physical' and type(v.get('policySamplingVersion')) is int and v['policySamplingVersion']==2 and
        v.get('hostFailureCount')==0 and type(v.get('automaticAttempts')) is int and 0<=v['automaticAttempts']<=2 for v in rows))
    for values in (rows,frames,decisions):
        require(all(finite(v.get('elapsed')) for v in values))
        require(all(b['elapsed']>a['elapsed'] for a,b in zip(values,values[1:])))
    events=rows[-1].get('automaticEvents');require(isinstance(events,list) and 1<=len(events)<=2)
    require(all(isinstance(e,dict) and type(e.get('attempt')) is int and 1<=e['attempt']<=2 for e in events))
    installs=[e for e in events if e.get('outcome')=='installed' and e['attempt']==2]
    require(len(installs)==1);install=installs[0]
    require(install.get('itemChanged') is True and install.get('credentialCommitAccepted') is True and finite(install.get('elapsedAfter')))
    installed_at=install['elapsedAfter']
    require(all(v['automaticAttempts']==2 and v.get('automaticEvents')==events for v in rows if v['elapsed']>=installed_at))
    published=[f for f in frames if type(f.get('frames')) is int and f['frames']>0]
    high=next((f for f in published if f['elapsed']>installed_at and f.get('width')==640),None);require(high is not None)
    after=[f for f in published if f['elapsed']>=high['elapsed']]
    require(type(high.get('generation')) is int and all(f.get('generation')==high['generation'] for f in after))
    low=next((f for f in after if f.get('width')==320),None);require(low is not None)
    require(any(f['elapsed']>low['elapsed'] and f.get('width')==320 and finite(f.get('position')) and
        finite(low.get('position')) and f['position']>low['position'] for f in after))
    require(all(d.get('sessionId')==session for d in decisions))
    tail=[d for d in decisions if d['elapsed']>=installed_at]
    require(bool(tail))
    authority=dict(generation=tail[0].get('generation'),
        intentRevision=install.get('ticketIntentRevision'),
        credentialRevision=install.get('ticketCredentialRevision'))
    require(all(type(value) is int and value>=0 for value in authority.values()))
    require(all(all(type(d.get(key)) is int and d[key]==value
        for key,value in authority.items()) for d in tail))
    require(all(type(d.get('attempts')) is int and d['attempts']==2 and d.get('reason') not in ('reserved','ticketReady') for d in tail))
    anchor=None;previous=None;windows=[];qualified=[]
    for d in tail:
        if d['elapsed']<low['elapsed']:continue
        eligible=(d.get('reason')=='budgetExhausted' and d.get('allowed') is True and d.get('sawHigh') is True and
            d.get('width')==320 and type(d.get('overdue')) is int and d['overdue']>0 and d.get('pendingDue') is None and
            all(finite(d.get(k)) for k in ('position','remaining','bufferAhead','bytes','transfer','requests')) and
            d['remaining']>=20 and d['bufferAhead']>=5 and
            all(type(d.get(k)) is int and d[k]>=0 for k in ('bytes','requests','generation','intentRevision','credentialRevision')))
        if not eligible:anchor=previous=None;windows=[];qualified=[];continue
        if previous and (any(d[k]!=previous[k] for k in ('generation','intentRevision','credentialRevision')) or
            any(d[k]<previous[k] for k in ('position','bytes','transfer','requests'))):
            anchor=None;windows=[];qualified=[]
        previous=d;qualified.append(d)
        if anchor is None:anchor=d;continue
        if d['elapsed']-anchor['elapsed']<8:continue
        duration=d['transfer']-anchor['transfer'];rate=(d['bytes']-anchor['bytes'])*8/duration if duration>0 else 0
        request_count=d['requests']-anchor['requests']
        if d['position']<=anchor['position'] or request_count<3 or not finite(rate) or rate<955000:
            windows=[];qualified=[];anchor=d;continue
        windows.append(dict(start=anchor['elapsed'],end=d['elapsed'],requests=request_count,bitrate=rate));anchor=d
        if len(windows)==2:break
    require(len(windows)==2)
    require(rows[-1]['elapsed']>=windows[-1]['end'])
    return dict(secondInstallElapsed=installed_at,secondDownshiftElapsed=low['elapsed'],
        exhaustedSamples=len(qualified),qualifiedCounterfactualWindows=windows,maximumAttempts=2,
        thirdReservationObserved=False,capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False)
