"""Owned Apple ABR access-log observation; does not certify adaptive policy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import threading
import time
import uuid
from xml.parsers.expat import ExpatError
from network_profile import load_profiles, make_server, owned_bind_host
from prepare_fixture import create
import abr_device


def policy_trace_version(rows):
    if not any(isinstance(row, dict) and 'policySamplingVersion' in row for row in rows):
        return None
    if not all(isinstance(row, dict) and type(row.get('policySamplingVersion')) is int and
               row['policySamplingVersion'] in (1,2) and row['policySamplingVersion'] == rows[0]['policySamplingVersion'] for row in rows):
        raise ValueError('inconsistent or unsupported policy sampling version')
    return rows[0]['policySamplingVersion']


def summarize_policy(rows, *, expected_attempts):
    """Validate exact native decisions; an untriggered run is not path coverage."""
    reasons = {'invalidSample', 'playbackIneligible', 'insufficientBuffer', 'nearEnd',
        'nonMonotonic', 'highOutput', 'highNotObserved', 'notLowOutput', 'noOverdue',
        'backoff', 'ticketReady', 'inFlight', 'budgetExhausted', 'windowStarted',
        'countersReset', 'windowPending', 'noProgress', 'insufficientRequests',
        'insufficientBandwidth', 'firstQualifiedWindow', 'reserved'}
    def require(value):
        if not value: raise ValueError('invalid recovery policy evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(type(expected_attempts) is int and 0 <= expected_attempts <= 2)
    require(isinstance(rows, list) and 1 <= len(rows) <= 1000)
    counts = {}; previous = -1; attempts = 0; reservations = 0; tickets = 0; pending = None
    rates = []; anchor = None; qualified = 0
    has_revision = any(isinstance(r,dict) and 'intentRevision' in r for r in rows)
    has_credentials = any(isinstance(r,dict) and 'credentialRevision' in r for r in rows)
    credential_revision = None; credential_samples = []
    revision = None; intent_samples = []; ticket_authorities = []
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get('reason'), str) and row['reason'] in reasons)
        if has_credentials:
            value = row.get('credentialRevision')
            require(type(value) is int and 0 <= value < 2**64 and (credential_revision is None or value >= credential_revision))
            if credential_revision is not None and value != credential_revision:
                anchor = None; qualified = 0; pending = None
            credential_revision = value
            credential_samples.append(dict(elapsed=row.get('elapsed'), credentialRevision=credential_revision))
        if has_revision:
            value = row.get('intentRevision')
            require(type(value) is int and 0 <= value < 2**64 and (revision is None or value >= revision))
            if revision is not None and value != revision:
                anchor = None; qualified = 0; pending = None
            revision = value
            intent_samples.append(dict(elapsed=row.get('elapsed'), intentRevision=revision))
        reason = row['reason']; elapsed = row.get('elapsed')
        require(finite(elapsed) and elapsed > previous); previous = elapsed
        for key in ('generation', 'width', 'overdue', 'qualifiedWindows'):
            require(type(row.get(key)) is int and row[key] >= 0)
        for key in ('bytes', 'requests'): require(type(row.get(key)) is int)
        require(row['qualifiedWindows'] <= 1)
        for key in ('allowed', 'sawHigh'): require(type(row.get(key)) is bool)
        for key in ('position', 'remaining', 'bufferAhead', 'transfer'):
            require(row.get(key) is None or (type(row.get(key)) in (int, float) and math.isfinite(row[key])))
        # Rejected samples may contain negative/unknown native inputs. Preserve
        # them only under the same guard priority as observe(); never qualify them.
        eligible = (row['allowed'] and all(finite(row[key]) for key in ('position', 'transfer')) and
                    row['bytes'] >= 0 and row['requests'] >= 0 and
                    row['bufferAhead'] is not None and row['bufferAhead'] >= 5 and
                    row['remaining'] is not None and row['remaining'] >= 20)
        rejection = None
        if not row['allowed']: rejection = 'playbackIneligible'
        elif row['bufferAhead'] is not None and row['bufferAhead'] < 5: rejection = 'insufficientBuffer'
        elif row['remaining'] is not None and row['remaining'] < 20: rejection = 'nearEnd'
        elif not eligible: rejection = 'invalidSample'
        if rejection is not None:
            require(reason == rejection)
        else:
            require(reason not in ('playbackIneligible', 'insufficientBuffer', 'nearEnd', 'invalidSample'))
            if reason == 'highOutput': require(row['width'] == 640 and row['sawHigh'])
            elif reason == 'highNotObserved': require(row['width'] != 640 and not row['sawHigh'])
            elif reason == 'notLowOutput': require(row['sawHigh'] and row['width'] not in (320, 640))
            elif reason == 'noOverdue': require(row['sawHigh'] and row['width'] == 320 and row['overdue'] == 0)
            elif reason != 'nonMonotonic':
                require(row['sawHigh'] and row['width'] == 320 and row['overdue'] > 0)
        budget = row.get('attempts')
        require(type(budget) is int and attempts <= budget <= 2)
        bitrate = row.get('windowBitrate'); requests = row.get('windowRequests'); due = row.get('pendingDue')
        require(bitrate is None or finite(bitrate))
        require(requests is None or (type(requests) is int and requests >= 0))
        require(due is None or finite(due))
        if bitrate is not None: rates.append(bitrate)
        completed_window = reason in ('noProgress', 'insufficientRequests',
            'insufficientBandwidth', 'firstQualifiedWindow', 'reserved')
        if completed_window:
            require(anchor is not None and row['generation'] == anchor['generation'] and
                    elapsed-anchor['elapsed'] >= 8)
            require(all(row[key] >= anchor[key] for key in ('bytes', 'transfer', 'requests')))
            duration = row['transfer']-anchor['transfer']
            measured = (row['bytes']-anchor['bytes'])*8/duration if duration > 0 else 0
            require(bitrate is not None and math.isclose(bitrate, measured, rel_tol=1e-9, abs_tol=1e-6))
            require(requests == row['requests']-anchor['requests'])
            if reason in ('firstQualifiedWindow', 'reserved'):
                require(row['position'] > anchor['position'])
                require(qualified == (0 if reason == 'firstQualifiedWindow' else 1))
                qualified = 1 if reason == 'firstQualifiedWindow' else 0
            else:
                qualified = 0
            anchor = None if reason == 'reserved' else row
        elif reason in ('windowStarted', 'countersReset'):
            anchor = row; qualified = 0
        elif reason == 'windowPending':
            require(anchor is not None and row['generation'] == anchor['generation'] and
                    elapsed-anchor['elapsed'] < 8)
        else:
            anchor = None; qualified = 0
        require(row['qualifiedWindows'] == qualified)
        if reason in ('reserved', 'firstQualifiedWindow'):
            require(bitrate is not None and bitrate >= 955000 and requests is not None and requests >= 3)
            require(row['allowed'] and row['sawHigh'] and row['width'] == 320 and
                    row['bufferAhead'] >= 5 and row['remaining'] >= 20 and row['overdue'] > 0)
        if reason == 'reserved':
            require(budget == attempts + 1 and due is not None and
                    math.isclose(due-elapsed, .5 if budget == 1 else 1, abs_tol=1e-6))
            pending = (budget, row['generation'], due, revision, credential_revision); reservations += 1
        else:
            require(budget == attempts)
            if reason == 'ticketReady':
                require(pending is not None and pending[0] == budget and
                        pending[1] == row['generation'] and elapsed >= pending[2] and pending[3] == revision and pending[4] == credential_revision)
                pending = None; tickets += 1
                if has_revision or has_credentials: ticket_authorities.append(dict(attempt=budget,elapsed=elapsed,intentRevision=revision,credentialRevision=credential_revision))
            elif reason != 'backoff': pending = None
        attempts = budget
        counts[reason] = counts.get(reason, 0) + 1
    require(attempts == expected_attempts)
    return dict(samples=len(rows), reasonCounts=counts, attempts=attempts,
        reservations=reservations, tickets=tickets, triggerExercised=tickets > 0,
        intentSamples=intent_samples, credentialSamples=credential_samples, ticketAuthorities=ticket_authorities,
        windowBitrateMinimum=min(rates) if rates else None,
        windowBitrateMaximum=max(rates) if rates else None, capabilityAccepted=False)



def validate_recovery_authority(rows, policy):
    """V2 binds every observed candidate to its transport/credential authority."""
    if policy_trace_version(rows) != 2: return
    def require(value):
        if not value: raise ValueError('invalid recovery credential authority')
    require(isinstance(policy,dict))
    require(isinstance(policy.get('intentSamples'),list) and bool(policy['intentSamples']))
    require(isinstance(policy.get('credentialSamples'),list) and bool(policy['credentialSamples']))
    events=rows[-1].get('automaticEvents');authorities=policy.get('ticketAuthorities')
    require(isinstance(events,list) and isinstance(authorities,list) and len(events)==len(authorities))
    for e,a in zip(events,authorities):
        require(isinstance(e,dict) and isinstance(a,dict) and type(e.get('attempt')) is int and e['attempt']==a.get('attempt'))
        require(all(type(x) in (int,float) and math.isfinite(x) for x in (e.get('elapsed'),a.get('elapsed'))))
        require(0<=e['elapsed']-a['elapsed']<=.05)
        for event_key,key in [('ticketIntentRevision','intentRevision'),('ticketCredentialRevision','credentialRevision')]:
            require(type(e.get(event_key)) is int and type(a.get(key)) is int and 0<=e[event_key]<2**64 and e[event_key]==a[key])


def summarize(rows, *, expected_duration_seconds=None, expected_transport=None, expected_startup_delay_ms=0,
              expected_recovery_action=None, expected_auto_scenario='normal'):
    def require(value):
        if not value: raise ValueError('incomplete or invalid ABR observation')
    require(isinstance(rows,list) and 2<=len(rows)<=1000)
    require(all(isinstance(row, dict) for row in rows))
    intervention = None
    if expected_recovery_action is None:
        require(all(row.get('recoveryAction') in (None, 'none') and
                    row.get('recoveryAttempt') is None for row in rows))
    if expected_recovery_action is not None:
        require(expected_recovery_action in ('none', 'seek-current', 'reload-source', 'auto-reload'))
        require(all(row.get('recoveryAction') == expected_recovery_action for row in rows))
        require(expected_auto_scenario in ('normal', 'pause-first', 'pause-during-preparation', 'pause-during-metadata', 'seek-during-preparation', 'caps-during-preparation', 'fixed-during-preparation'))
        require(all(row.get('autoScenario') == expected_auto_scenario for row in rows))
        require(all(type(row.get('frameSamplingVersion')) is int and row['frameSamplingVersion'] == 2 for row in rows))
        attempts = [row.get('recoveryAttempt') for row in rows if row.get('recoveryAttempt') is not None]
        if expected_recovery_action == 'auto-reload':
            require(not attempts)
            previous = 0
            final = rows[-1].get('automaticEvents')
            require(isinstance(final, list) and len(final) <= 2)
            for row in rows:
                budget = row.get('automaticAttempts')
                require(type(budget) is int and previous <= budget <= 2)
                previous = budget
                events = row.get('automaticEvents')
                require(isinstance(events, list) and events == final[:len(events)] and len(events) <= budget)
            previous_attempt = 0
            for event in final:
                require(isinstance(event, dict) and type(event.get('attempt')) is int and
                        previous_attempt < event['attempt'] <= previous)
                previous_attempt = event['attempt']
                require(event.get('outcome') in ('installed', 'cancelled', 'preparationFailed'))
                for key in ('elapsed', 'elapsedAfter', 'due', 'positionBefore'):
                    require(type(event.get(key)) in (int, float) and math.isfinite(event[key]) and event[key] >= 0)
                require(event['due'] <= event['elapsed'] <= event['elapsedAfter'] <= rows[-1]['elapsed'])
                if event['outcome'] == 'installed':
                    require(event.get('itemChanged') is True)
                    if intervention is None: intervention = event
        elif expected_recovery_action == 'none':
            require(not attempts)
        else:
            require(bool(attempts) and all(attempt == attempts[0] for attempt in attempts))
            attempt = attempts[0]
            require(isinstance(attempt, dict) and attempt.get('action') == expected_recovery_action)
            require(rows[-1].get('recoveryAttempt') == attempt)
            require(attempt.get('completed') is True)
            require(attempt.get('itemChanged') is (expected_recovery_action == 'reload-source'))
            for key in ('elapsed', 'positionBefore'):
                require(type(attempt.get(key)) in (int, float) and math.isfinite(attempt[key]) and attempt[key] >= 0)
            require(rows[0]['elapsed'] <= attempt['elapsed'] <= rows[-1]['elapsed'])
            if 'elapsedAfter' in attempt:
                require(type(attempt['elapsedAfter']) in (int, float) and math.isfinite(attempt['elapsedAfter']) and
                        attempt['elapsed'] <= attempt['elapsedAfter'] <= rows[-1]['elapsed'])
            intervention = attempt
    if expected_duration_seconds is not None or expected_transport is not None:
        require(type(expected_duration_seconds) is int and expected_duration_seconds in (40, 120))
        require(expected_transport in ('managed-dash', 'direct-hls-control'))
        require(type(expected_startup_delay_ms) is int and 0 <= expected_startup_delay_ms <= 2000)
        require(all(type(row.get('programmeDurationSeconds')) is int and
                    row.get('programmeDurationSeconds') == expected_duration_seconds and
                    type(row.get('startupDelayMs')) is int and row['startupDelayMs'] == expected_startup_delay_ms and
                    row.get('transport') == expected_transport for row in rows))
        position = rows[-1].get('position')
        require(type(position) in (int, float) and math.isfinite(position) and
                position >= expected_duration_seconds - .5)
    widths=[];previous=-1
    for row in rows:
        elapsed=row['elapsed']
        require(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed>previous)
        previous=elapsed
        require(row['peak']==0 and row['status'] in (0,1))
        width=row['width'];require(type(width) in (int,float) and math.isfinite(width) and 0<=width<=16384)
        if width and (not widths or width!=widths[-1]):widths.append(width)
    require(rows[-1]['completed'] is True and type(rows[-1]['framesPublished']) is int and rows[-1]['framesPublished']>0)
    last=(rows[-1].get('logs') or [{}])[-1]
    observed=last.get('observedBitrate')
    require(observed is None or (type(observed) in (int,float) and math.isfinite(observed)))
    recovered=False;down=False
    for a,b in zip(widths,widths[1:]):
        if b<a:down=True
        elif down and b>a:recovered=True
    return dict(schemaVersion=1,geometryWidths=widths,downshiftObserved=down,
        recoveryInterventionApplied=intervention is not None,
        highOutputAfterInterventionObserved=(any(row['elapsed'] > intervention.get('elapsedAfter', intervention['elapsed']) and
            row['width'] == 640 for row in rows) if intervention else None),
        upshiftAfterDownshiftObserved=recovered,lastObservedBitrate=observed,
        lastIndicatedBitrate=last.get('indicatedBitrate'),framesPublished=rows[-1]['framesPublished'],
        diagnosticOnly=True,internalABRDecisionVerified=False,capabilityAccepted=False,
        physicalOutputVerified=False)


def summarize_public_policy(rows, frames, events):
    """Require real typed-host policy commits and frame evidence for every phase."""
    phases = ['initial-auto', 'caps', 'clear-caps', 'fixed', 'restore-auto']
    def require(value):
        if not value: raise ValueError('incomplete public host policy evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(isinstance(rows, list) and bool(rows) and isinstance(frames, list))
    require(isinstance(events, list) and len(events) == 4)
    session = rows[0].get('sessionId')
    require(isinstance(session, str) and bool(session))
    previous = -1
    for phase, event in zip(phases[1:], events):
        require(isinstance(event, dict) and event.get('phase') == phase and
                event.get('applied') is True and event.get('itemChanged') is True and
                event.get('sessionId') == session and finite(event.get('elapsed')) and
                finite(event.get('elapsedAfter')) and previous < event['elapsed'] <= event['elapsedAfter'])
        previous = event['elapsedAfter']
    require(all(isinstance(row, dict) and row.get('publicPolicyCycle') is True and
                row.get('sessionId') == session and row.get('hostFailureCount') == 0 and
                row.get('hostStatus') in ('loading', 'ready', 'playing', 'paused', 'buffering', 'completed') and finite(row.get('elapsed'))
                for row in rows))
    require(all(a['elapsed'] < b['elapsed'] for a, b in zip(rows, rows[1:])))
    require(all(isinstance(frame, dict) and finite(frame.get('elapsed')) and
                type(frame.get('frames')) is int and frame['frames'] >= 0 and
                type(frame.get('width')) is int and 0 <= frame['width'] <= 16384 for frame in frames))
    require(all(a['elapsed'] < b['elapsed'] for a, b in zip(frames, frames[1:])))
    observed = []
    for row in rows:
        phase = row.get('policyPhase')
        require(phase in phases)
        if not observed or observed[-1] != phase: observed.append(phase)
    require(observed == phases)
    summaries = []
    for i, phase in enumerate(phases):
        start = events[i-1]['elapsedAfter'] if i else rows[0]['elapsed']
        end = events[i]['elapsed'] if i < 4 else rows[-1]['elapsed'] + 1
        selected = [row for row in rows if row['policyPhase'] == phase]
        require(len(selected) >= 3 and all(start <= row['elapsed'] <= end for row in selected))
        expected_id = 'dash-video-w320-h180-b350000' if phase == 'fixed' else None
        require(all(row.get('fixedTrackId') == expected_id and
                    'fixedTrackId' in row and 'acceptedMaximumWidth' in row and
                    row.get('acceptedMaximumWidth') == (320 if phase == 'caps' else None) and
                    'acceptedMaximumHeight' in row and row['acceptedMaximumHeight'] is None and
                    'acceptedMaximumBitrate' in row and row['acceptedMaximumBitrate'] is None and
                    row.get('peak') == 0 and row.get('maximumWidth') == (320 if phase == 'caps' else 0) and
                    row.get('maximumHeight') == (100000 if phase == 'caps' else 0)
                    for row in selected))
        published = [frame for frame in frames if start <= frame['elapsed'] < end and frame['frames'] > 0]
        require(len(published) >= 3)
        widths = sorted(set(frame['width'] for frame in published))
        if phase in ('caps', 'fixed'): require(widths == [320])
        else: require(640 in widths)
        summaries.append(dict(phase=phase, rows=len(selected), publishedFrames=sum(f['frames'] for f in published), widths=widths))
    return dict(phasesVerified=phases, phases=summaries, sameSession=True,
                capabilityAccepted=False, physicalOutputVerified=False, continuityAccepted=False)


def public_policy_race(args):
    enabled = getattr(args, 'public_policy_race', False)
    if type(enabled) is not bool or (enabled and (
            getattr(args, 'public_policy_cycle', False) or
            getattr(args, 'duration_seconds', 40) != 120 or
            getattr(args, 'direct_hls_control', False) or
            getattr(args, 'recovery_action', 'none') != 'auto-reload' or
            getattr(args, 'auto_scenario', 'normal') not in ('caps-during-preparation', 'fixed-during-preparation', 'pause-during-preparation', 'seek-during-preparation') or
            getattr(args, 'candidate_preparation', 'manifest-only') != 'asset-preroll' or
            getattr(args, 'startup_delay_ms', 0) != 0)):
        raise ValueError('public policy race requires owned 120s caps/fixed preroll diagnostic')
    return enabled


def summarize_public_transport(rows, frames, policy):
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
    require(type(e.get('ticketIntentRevision')) is int and e['ticketIntentRevision']==before)
    authorities=policy.get('ticketAuthorities');samples=policy.get('intentSamples')
    require(isinstance(authorities,list) and len(authorities)==len(events) and isinstance(samples,list) and samples)
    for event,authority in zip(events,authorities):
        require(authority.get('attempt')==event.get('attempt') and
                authority.get('intentRevision')==event.get('ticketIntentRevision') and
                finite(authority.get('elapsed')) and abs(authority['elapsed']-event['elapsed'])<=.05)
    def validate_revisions(trace,key):
        previous_revision=None
        require(any(r['elapsed']<=e['publicCommandStartedElapsed'] for r in trace) and
                any(r['elapsed']>=e['publicCommandCompletedElapsed'] for r in trace))
        for r in trace:
            revision=r.get(key)
            require(type(revision) is int and 0<=revision<2**64 and
                    (previous_revision is None or revision>=previous_revision))
            require(revision in (before,after))
            if r['elapsed']<=e['publicCommandStartedElapsed']:require(revision==before)
            if r['elapsed']>=e['publicCommandCompletedElapsed']:require(revision==after)
            previous_revision=revision
    validate_revisions(rows,'publicIntentRevision')
    validate_revisions(samples,'intentRevision')
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
    if scenario=='seek-during-preparation':
        for f in published:
            pts=f.get('framePresentationTimes')
            require(isinstance(pts,list) and len(pts)==f['frames'] and
                    all(finite(t) and t>=target/1000-.05 for t in pts))
        require(all(f['position']>=target/1000-.05 for f in published))
    require(published[-1]['position']>published[0]['position']+.1)
    return dict(scenario=scenario,oldCandidateRejected=True,sameItem=True,sameSession=True,
                sourceAttempts=previous,publishedFrames=sum(f['frames'] for f in published),
                capabilityAccepted=False,continuityAccepted=False,physicalOutputVerified=False)


def summarize_public_race(rows, frames, policy):
    """Reject missing races: a naturally issued ticket and real command must win."""
    if isinstance(rows,list) and rows and isinstance(rows[0],dict) and rows[0].get('autoScenario') in ('pause-during-preparation','seek-during-preparation'):
        return summarize_public_transport(rows,frames,policy)
    def require(value):
        if not value: raise ValueError('incomplete public host preparation race evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(isinstance(rows, list) and len(rows) >= 4 and isinstance(frames, list))
    require(isinstance(policy, dict) and policy.get('triggerExercised') is True and
            all(type(policy.get(k)) is int and policy[k] == 1 for k in ('reservations', 'tickets', 'attempts')))
    require(all(isinstance(r, dict) and finite(r.get('elapsed')) for r in rows))
    require(all(a['elapsed'] < b['elapsed'] for a,b in zip(rows, rows[1:])))
    session = rows[0].get('sessionId'); scenario = rows[0].get('autoScenario')
    require(isinstance(session, str) and bool(session) and
            scenario in ('caps-during-preparation', 'fixed-during-preparation'))
    events = rows[-1].get('automaticEvents')
    require(isinstance(events, list) and len(events) == 1 and isinstance(events[0], dict))
    e = events[0]
    require(type(e.get('attempt')) is int and e['attempt'] == 1 and e.get('outcome') == 'preparationFailed')
    require(all(e.get(k) is True for k in ('publicCommandApplied', 'publicCommandItemChanged',
                                          'publicCommandReady', 'warmupDetached')))
    require(all(e.get(k) is False for k in ('publicCommandManuallyInvalidated',
                'warmupReusesPrerolledItem', 'warmupOldItemRetained')))
    require(e.get('publicCommandSessionId') == session and e.get('warmupOutcome') == 'cancelled' and
            e.get('warmupStage') == 'waitingReady' and e.get('freshPreparedItemInstalled') is not True)
    keys = ('due', 'elapsed', 'publicCommandStartedElapsed', 'publicCommandCompletedElapsed', 'elapsedAfter')
    require(all(finite(e.get(k)) for k in keys))
    require(all(e[a] <= e[b] for a,b in zip(keys,keys[1:])) and e['elapsedAfter'] <= rows[-1]['elapsed'])
    require(all(finite(e.get(k)) for k in ('warmupStartedElapsed', 'warmupDeadlineElapsed', 'warmupCompletedElapsed')))
    deadline = min(e['warmupStartedElapsed'] + 2, e['due'] + 5)
    require(math.isclose(e['warmupDeadlineElapsed'], deadline, rel_tol=0, abs_tol=1e-6))
    require(e['elapsed'] <= e['warmupStartedElapsed'] <= e['publicCommandStartedElapsed'] <= e['warmupCompletedElapsed'] <= deadline)
    require(e['publicCommandCompletedElapsed'] <= deadline and e['warmupCompletedElapsed'] <= e['elapsedAfter'])
    previous = 0
    for r in rows:
        require(r.get('publicPolicyRace') is True and r.get('publicPolicyCycle') is False and
                r.get('autoScenario') == scenario and r.get('sessionId') == session and
                r.get('hostFailureCount') == 0 and
                r.get('hostStatus') in ('loading', 'ready', 'playing', 'paused', 'buffering', 'completed'))
        budget = r.get('automaticAttempts'); history = r.get('automaticEvents')
        require(type(budget) is int and previous <= budget <= 1 and
                isinstance(history, list) and history == events[:len(history)] and len(history) <= budget)
        previous = budget
    require(previous == 1)
    selected = [r for r in rows if r['elapsed'] >= e['elapsedAfter']]
    fixed = 'dash-video-w320-h180-b350000' if scenario == 'fixed-during-preparation' else None
    cap = None if fixed else 320
    require(len(selected) >= 3)
    for r in selected:
        expected = dict(acceptedMaximumWidth=cap, acceptedMaximumHeight=None, acceptedMaximumBitrate=None,
                        fixedTrackId=fixed, maximumWidth=cap or 0, maximumHeight=100000 if cap else 0, peak=0)
        require(all(k in r and r[k] == v for k,v in expected.items()))
    require(all(isinstance(f, dict) and finite(f.get('elapsed')) and
                type(f.get('frames')) is int and f['frames'] >= 0 and
                type(f.get('width')) is int and 0 <= f['width'] <= 16384 for f in frames))
    require(all(a['elapsed'] < b['elapsed'] for a,b in zip(frames,frames[1:])))
    published = [f for f in frames if f['elapsed'] >= e['publicCommandCompletedElapsed'] and f['frames'] > 0]
    require(len(published) >= 3 and all(f['width'] == 320 for f in published))
    return dict(scenario=scenario, oldCandidateRejected=True, sameSession=True,
                sourceAttempts=1, policyRows=len(selected), publishedFrames=sum(f['frames'] for f in published),
                capabilityAccepted=False, continuityAccepted=False, physicalOutputVerified=False)


def public_policy_cycle(args):
    enabled = getattr(args, 'public_policy_cycle', False)
    if type(enabled) is not bool or (enabled and (
            getattr(args, 'duration_seconds', 40) != 120 or
            getattr(args, 'direct_hls_control', False) or
            getattr(args, 'recovery_action', 'none') != 'none' or
            getattr(args, 'auto_scenario', 'normal') != 'normal' or
            getattr(args, 'candidate_preparation', 'manifest-only') != 'manifest-only' or
            getattr(args, 'startup_delay_ms', 0) != 0)):
        raise ValueError('public policy cycle requires managed 120s with no recovery intervention')
    return enabled


def summarize_frames(rows, *, expected_frames):
    def require(value):
        if not value: raise ValueError('invalid frame publication observation')
    require(type(expected_frames) is int and expected_frames > 0 and 2 <= len(rows) <= 15000)
    previous_time = -1; generation = 0; total = 0; published = []; pump_gaps = []
    has_clears = any('textureClears' in row for row in rows if isinstance(row, dict))
    previous_clears = 0; generations = set()
    for row in rows:
        require(isinstance(row, dict))
        elapsed = row.get('elapsed'); position = row.get('position')
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed > previous_time)
        require(type(position) in (int, float) and math.isfinite(position) and position >= 0)
        require(type(row.get('generation')) is int and generation <= row['generation'])
        generation = row['generation']
        generations.add(generation)
        if has_clears:
            require(type(row.get('textureClears')) is int and row['textureClears'] >= previous_clears)
            previous_clears = row['textureClears']
        count = row.get('frames'); require(type(count) is int and 0 <= count <= 2)
        require(type(row.get('width')) is int and (row['width'] in (320, 640) if count else row['width'] == 0))
        if previous_time >= 0: pump_gaps.append((elapsed - previous_time) * 1000)
        previous_time = elapsed; total += count
        if count: published.append(row)
    require(total == expected_frames)
    boundaries = [dict(generationBefore=a['generation'], generationAfter=b['generation'],
        elapsedBefore=a['elapsed'], elapsedAfter=b['elapsed'],
        publicationGapMs=(b['elapsed']-a['elapsed'])*1000,
        positionDeltaMs=(b['position']-a['position'])*1000,
        textureClears=b['textureClears']-a['textureClears'] if has_clears else None)
        for a,b in zip(published,published[1:]) if a['generation'] != b['generation']]
    return dict(frameSamplingVersion=2, sampleCount=len(rows), publishedFrames=total,
        maximumPumpGapMs=max(pump_gaps),
        maximumPublishedFrameGapMs=max(((b['elapsed']-a['elapsed'])*1000 for a,b in zip(published,published[1:])), default=None),
        lastPublicationSampleElapsed=published[-1]['elapsed'],
        observationEndElapsed=rows[-1]['elapsed'],
        trailingNoPublicationMs=(rows[-1]['elapsed']-published[-1]['elapsed'])*1000,
        replacementBoundaries=boundaries,
        generationsWithoutPublishedFrame=sorted(generations - {row['generation'] for row in published}),
        continuityAccepted=False, audioSynchronizationVerified=False, physicalOutputVerified=False)


def read_rows(path):
    if path.stat().st_size>16*1024*1024:raise ValueError('observation exceeds 16 MiB')
    return [json.loads(line) for line in path.read_text().splitlines()]


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
                            capture_output=True, text=True, timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError('cannot inspect owned process')
    return result.stdout.strip()


def cleanup_owned(owned):
    if owned is None:
        return False
    pid, identity = owned
    current = process_identity(pid)
    if not current:
        return True
    if current != identity:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(40):
        current = process_identity(pid)
        if not current:
            return True
        if current != identity:
            return False
        time.sleep(.1)
    return False


def observe_owned(out, token, executable):
    proof = out / 'process.json'
    if not proof.exists():
        return None
    if proof.stat().st_size > 4096:
        raise ValueError('invalid process proof')
    value = json.loads(proof.read_text())
    pid = value['pid']
    path = value['executable']
    if (value['token'] != token or type(pid) is not int or pid <= 1 or
        not isinstance(path, str) or Path(path).name != executable or '.app/' not in path):
        raise ValueError('invalid process proof')
    identity = process_identity(pid)
    if identity:
        # macOS reports the canonical /private/tmp path in ps while the native
        # host may launch through /tmp. Preserve the full start-time identity
        # for cleanup, but compare the executable's resolved path here.
        fields = identity.split(maxsplit=5)
        if (len(fields) != 6 or
                Path(fields[5]).resolve(strict=True) != Path(path).resolve(strict=True)):
            raise ValueError('process proof executable mismatch')
    return (pid, identity) if identity else None


def wait_for_native(process, command, observe, timeout=240):
    deadline = time.monotonic() + timeout
    while (code := process.poll()) is None:
        observe()
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(command, timeout)
        time.sleep(.25)
    # A child can exit during sleep, or the parent can resume after its deadline.
    # Observing exit 0 at that point is not evidence of timely completion.
    if time.monotonic() >= deadline:
        raise subprocess.TimeoutExpired(command, timeout)
    return code


def candidate_preparation(args):
    mode = getattr(args, 'candidate_preparation', 'manifest-only')
    if mode not in ('manifest-only', 'asset-metadata', 'asset-preroll'):
        raise ValueError('invalid candidate preparation')
    if mode != 'manifest-only' and (getattr(args, 'recovery_action', 'none') != 'auto-reload' or
            getattr(args, 'duration_seconds', 40) != 120 or getattr(args, 'direct_hls_control', False)):
        raise ValueError('candidate preparation requires managed 120s automatic diagnostic')
    required_mode = {'caps-during-preparation': 'asset-preroll',
                     'fixed-during-preparation': 'asset-preroll',
                     'pause-during-preparation': 'asset-preroll',
                     'seek-during-preparation': 'asset-preroll',
                     'pause-during-metadata': 'asset-metadata'}.get(getattr(args, 'auto_scenario', 'normal'))
    if required_mode is not None and mode != required_mode:
        raise ValueError('intent scenario does not match candidate preparation')
    return mode


def validate_candidate_preparation(rows, expected):
    if expected not in ('manifest-only', 'asset-metadata', 'asset-preroll') or not rows or not all(
            isinstance(row, dict) and row.get('candidatePreparation', 'manifest-only') == expected
            for row in rows):
        raise ValueError('native candidate preparation does not match request')
    if expected == 'asset-preroll':
        for row in rows:
            events = row.get('automaticEvents', [])
            if not isinstance(events, list):
                raise ValueError('invalid preroll event evidence')
            for event in events:
                if not isinstance(event, dict):
                    raise ValueError('invalid preroll event evidence')
                if event.get('outcome') == 'installed' and not (
                        event.get('warmupOutcome') == 'ready' and event.get('warmupStage') == 'ready' and
                        event.get('warmupDetached') is True and event.get('warmupReusesPrerolledItem') is False and
                        event.get('freshPreparedItemInstalled') is True and event.get('warmupOldItemRetained') is True):
                    raise ValueError('preroll installation lacks fresh item preparation evidence')


def run(args):
    out=args.directory.resolve();out.mkdir(parents=True,exist_ok=False)
    receipt=dict(diagnosticOnly=True,capabilityAccepted=False,errors=[],exitCode=None)
    server=None;thread=None;process=None;log=None;output=None;owned=None
    token=uuid.uuid4().hex
    before=None;products=None
    physical_device = getattr(args, 'physical_device', None)
    bundle = None; executable = None
    receipt['deviceKind'] = 'physical' if physical_device else ('simulator' if args.device else 'macos')
    def hashes():
        paths=[p for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')]
        return {str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    try:
        cycle = public_policy_cycle(args)
        race = public_policy_race(args)
        receipt['publicPolicyRace'] = race
        receipt['publicPolicyCycle'] = cycle
        host = getattr(args, 'owned_host', None)
        if physical_device:
            if args.device or not re.fullmatch('[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}', physical_device) or host is None:
                raise ValueError('invalid physical device selection')
            host = owned_bind_host(host)
        elif host is not None:
            raise ValueError('private listener requires physical device selection')
        else: host = '127.0.0.1'
        duration_seconds = getattr(args, 'duration_seconds', 40)
        direct = getattr(args, 'direct_hls_control', False)
        startup_delay_ms = getattr(args, 'startup_delay_ms', 0)
        recovery_action = getattr(args, 'recovery_action', 'none')
        auto_scenario = getattr(args, 'auto_scenario', 'normal')
        if auto_scenario not in ('normal', 'pause-first', 'pause-during-preparation', 'pause-during-metadata', 'seek-during-preparation', 'caps-during-preparation', 'fixed-during-preparation') or (auto_scenario != 'normal' and recovery_action != 'auto-reload'):
            raise ValueError('invalid automatic recovery scenario')
        receipt['autoScenario'] = auto_scenario
        preparation_mode = candidate_preparation(args)
        receipt['candidatePreparation'] = preparation_mode
        if recovery_action not in ('none', 'seek-current', 'reload-source', 'auto-reload') or (direct and recovery_action != 'none'):
            raise ValueError('invalid managed recovery diagnostic')
        if recovery_action != 'none' and duration_seconds != 120:
            raise ValueError('recovery diagnostic requires 120 seconds')
        receipt['recoveryAction'] = recovery_action
        if type(startup_delay_ms) is not int or not 0 <= startup_delay_ms <= 2000:
            raise ValueError('invalid diagnostic startup delay')
        receipt['transport'] = 'direct-hls-control' if direct else 'managed-dash'
        receipt['startupDelayMs'] = startup_delay_ms
        products=args.products.resolve(strict=True)
        manifests=list(products.glob('*.xctestrun'))
        if len(manifests)!=1:raise ValueError('expected one built test manifest')
        def absolute(value):
            if isinstance(value,str):return value.replace('__TESTROOT__',str(products))
            if isinstance(value,list):return [absolute(x) for x in value]
            if isinstance(value,dict):return {k:absolute(v) for k,v in value.items()}
            return value
        config=absolute(plistlib.loads(manifests[0].read_bytes()))
        target=config['RunnerTests']
        app=Path(target['TestHostPath'])
        if app.suffix!='.app':
            app=app.parent
            if app.name=='MacOS':app=app.parent.parent
        info=app/('Contents/Info.plist' if (app/'Contents').is_dir() else 'Info.plist')
        executable=plistlib.loads(info.read_bytes())['CFBundleExecutable']
        if physical_device: bundle=plistlib.loads(info.read_bytes())['CFBundleIdentifier']
        before=hashes();receipt['binaryHashes']=before
        receipt['fixture']=create(out/'fixture', duration_seconds=duration_seconds,
                                  direct_hls_control=direct)
        profile=load_profiles(args.profiles)[args.profile];receipt['profileSha256']=profile.sha256
        destination='platform=macOS,arch=arm64'
        if args.device:
            if not re.fullmatch('[0-9A-Fa-f-]{36}',args.device):raise ValueError('invalid simulator identifier')
            destination='platform=iOS Simulator,id='+args.device
        if physical_device: destination='platform=iOS,id='+physical_device
        log=(out/'requests.jsonl').open('w');output=(out/'xcode.log').open('w')
        server=make_server(out/'fixture',profile,log,0,start_on_first_get=True,run_id='abr-accesslog',
                           owned_host=host if physical_device else None)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        target.setdefault('EnvironmentVariables',{}).update(
            YL_ABR_PROBE_TOKEN=token,YL_ABR_PROBE_URL=f'http://{host}:{server.server_port}/manifest.mpd',YL_ABR_PROBE_DIRECTORY=str(out),
            YL_ABR_PROBE_DEVICE='1' if physical_device else '0', YL_ABR_PROBE_OWNED_HOST=host if physical_device else '',
            YL_ABR_PROBE_SECONDS=str(duration_seconds), YL_ABR_PROBE_DIRECT_HLS='1' if direct else '0',
            YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,
            YL_ABR_PROBE_PUBLIC_POLICY_CYCLE='1' if cycle else '0',
            YL_ABR_PROBE_PUBLIC_POLICY_RACE='1' if race else '0',
            YL_ABR_PROBE_AUTO_SCENARIO=auto_scenario,
            YL_ABR_PROBE_CANDIDATE_PREPARATION=preparation_mode,
            YL_ABR_PROBE_STARTUP_DELAY_MS=str(startup_delay_ms), YL_ABR_PROBE_PROFILE_SHA256=profile.sha256)
        manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
        command=['xcodebuild','test-without-building','-quiet','-xctestrun',str(manifest),
            '-destination',destination,'-only-testing:RunnerTests/YlDashResourceLoaderTests/testActualOwnedDashAdaptiveObservation',
            '-parallel-testing-enabled','NO','-resultBundlePath',str(out)+'.xcresult']
        process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            def observe():
                nonlocal owned
                if not physical_device and owned is None:owned=observe_owned(out,token,executable)
            receipt['exitCode']=wait_for_native(process, command, observe)
        except subprocess.TimeoutExpired:
            receipt['errors'].append('native deadline')
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
        if physical_device: abr_device.collect(physical_device, bundle, out, token)
        rows=read_rows(out/'rows.jsonl')
        if not rows or not isinstance(rows[-1], dict):
            raise ValueError('missing final ABR observation')
        if physical_device and not all(isinstance(row, dict) and row.get('captureDeviceKind') == 'physical' for row in rows):
            raise ValueError('physical capture requires native device identity')
        policy_version = policy_trace_version(rows)
        if recovery_action == 'auto-reload' and policy_version in (1,2):
            receipt['policyObservation'] = summarize_policy(read_rows(out/'policy-decisions.jsonl'),
                expected_attempts=rows[-1]['automaticAttempts'])
            validate_recovery_authority(rows,receipt['policyObservation'])
        # Keep valid publication evidence even when playback never reaches EOF.
        receipt['continuityObservation'] = summarize_frames(read_rows(out/'frame-samples.jsonl'),
            expected_frames=rows[-1]['framesPublished'])
        if race:
            receipt['publicRaceObservation'] = summarize_public_race(rows,
                read_rows(out/'frame-samples.jsonl'), receipt.get('policyObservation'))
        elif any(row.get('publicPolicyRace') is True for row in rows):
            raise ValueError('unexpected public host preparation race')
        if cycle:
            receipt['publicPolicyObservation'] = summarize_public_policy(rows,
                read_rows(out/'frame-samples.jsonl'), json.loads((out/'public-policy-events.json').read_text()))
        elif any(row.get('publicPolicyCycle') is True for row in rows):
            raise ValueError('unexpected public host policy capture')
        validate_candidate_preparation(rows, preparation_mode)
        receipt['observation']=summarize(rows, expected_duration_seconds=duration_seconds,
                                         expected_transport=receipt['transport'], expected_startup_delay_ms=startup_delay_ms,
                                         expected_recovery_action=recovery_action, expected_auto_scenario=auto_scenario)
    except (OSError,ValueError,KeyError,TypeError,plistlib.InvalidFileException,ExpatError,
            subprocess.SubprocessError) as error:
        receipt['errors'].append(type(error).__name__)
    finally:
        if process is not None and process.poll() is None:
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=10)
        try:
            receipt['ownedProcessExited']=(abr_device.cleanup(physical_device,out,token,executable)
                if physical_device and executable else cleanup_owned(owned))
        except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError):
            receipt['ownedProcessExited']=False
        if process is not None and not receipt['ownedProcessExited']:
            receipt['errors'].append('owned process cleanup unverified')
        if server:server.shutdown();server.server_close()
        if thread:thread.join(timeout=5)
        if log:log.close()
        if output:output.close()
        receipt['binaryIdentityUnchanged']=False
        if before is not None:
            try:
                receipt['binaryIdentityUnchanged']=before==hashes()
            except OSError:
                receipt['errors'].append('binary identity recheck failed')
        receipt['passed']=(receipt['exitCode']==0 and not receipt['errors'] and receipt['binaryIdentityUnchanged']
                           and isinstance(receipt.get('observation'), dict)
                           and isinstance(receipt.get('continuityObservation'), dict))
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--products',type=Path,required=True);p.add_argument('--directory',type=Path,required=True)
    p.add_argument('--device',help='Explicit iOS Simulator UUID; omit for native arm64 macOS')
    p.add_argument('--physical-device', help='Explicit paired iPhone UDID; requires --owned-host')
    p.add_argument('--owned-host', help='Explicit owned RFC1918 IPv4 interface for physical-device capture')
    p.add_argument('--profiles',type=Path,default=Path(__file__).with_name('profiles.json'))
    p.add_argument('--duration-seconds',type=int,choices=(40,120),default=40)
    p.add_argument('--startup-delay-ms',type=int,default=0,
                   help='0..2000ms diagnostic delay after arming/preparing; never changes the frozen profile')
    p.add_argument('--recovery-action', choices=('none', 'seek-current', 'reload-source', 'auto-reload'), default='none',
                   help='one managed 120s diagnostic intervention; never natural ABR acceptance')
    p.add_argument('--auto-scenario', choices=('normal', 'pause-first', 'pause-during-preparation', 'pause-during-metadata', 'seek-during-preparation', 'caps-during-preparation', 'fixed-during-preparation'), default='normal')
    p.add_argument('--candidate-preparation', choices=('manifest-only', 'asset-metadata', 'asset-preroll'), default='manifest-only',
                   help='owned diagnostic only; requires native mode echo and unchanged ticket revalidation')
    p.add_argument('--public-policy-race', action='store_true',
                   help='typed public caps/fixed command after candidate readiness; requires cancellation')
    p.add_argument('--public-policy-cycle', action='store_true',
                   help='typed public host auto/caps/clear/fixed/auto media matrix; no recovery intervention')
    p.add_argument('--direct-hls-control',action='store_true',
                   help='system-only direct HLS control; not a production DASH acceptance run')
    p.add_argument('--profile',default='down-and-recover-v1');a=p.parse_args()
    result=run(a);print(json.dumps({k:v for k,v in result.items() if k!='binaryHashes'},indent=2))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
