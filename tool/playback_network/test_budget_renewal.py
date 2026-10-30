import copy
import unittest
from types import SimpleNamespace
import abr_accesslog


def trace():
    rows=[]
    def add(t, reason, attempts, qualified=0, limit=2, reservation=None, installation=None, **extra):
        row=dict(elapsed=t, sessionId='same', generation=0, intentRevision=0,
            credentialRevision=0, allowed=True, width=320, position=t, remaining=120-t,
            bufferAhead=10, bytes=int(t*200000), transfer=t, requests=int(t*4), overdue=1,
            reason=reason, attempts=attempts, qualifiedWindows=qualified, sawHigh=True,
            windowBitrate=None, windowRequests=None, pendingDue=None, budgetVersion=2,
            roundLimit=limit, lastReservation=reservation, lastInstallation=installation,
            highFrameCount=0, highFrameSeconds=0, highFrameStart=None)
        row.update(extra);rows.append(row)
    add(1,'windowStarted',0)
    add(9,'firstQualifiedWindow',0,1,windowBitrate=1600000,windowRequests=32)
    add(17,'reserved',1,reservation=17,windowBitrate=1600000,windowRequests=32,pendingDue=17.5)
    add(17.2,'playbackIneligible',1,reservation=17,allowed=False,intentRevision=1)
    add(19,'windowStarted',1,reservation=17,intentRevision=2)
    add(27,'firstQualifiedWindow',1,1,reservation=17,intentRevision=2,windowBitrate=1600000,windowRequests=32)
    add(35,'cooldown',1,2,reservation=17,intentRevision=2,windowBitrate=1600000,windowRequests=32)
    add(43,'cooldown',1,2,reservation=17,intentRevision=2,windowBitrate=1600000,windowRequests=32)
    add(47,'reserved',2,reservation=47,intentRevision=2,pendingDue=48)
    add(48,'ticketReady',2,reservation=47,intentRevision=2)
    add(49,'highOutput',2,reservation=47,installation=48.1,intentRevision=2,width=640)
    add(52,'highOutput',2,limit=4,reservation=47,installation=48.1,intentRevision=2,width=640,
        highFrameCount=49,highFrameSeconds=2,highFrameStart=50)
    add(53,'windowStarted',2,limit=4,reservation=47,installation=48.1,intentRevision=2)
    add(61,'firstQualifiedWindow',2,1,limit=4,reservation=47,installation=48.1,intentRevision=2,windowBitrate=1600000,windowRequests=32)
    add(69,'cooldown',2,2,limit=4,reservation=47,installation=48.1,intentRevision=2,windowBitrate=1600000,windowRequests=32)
    add(77,'reserved',3,limit=4,reservation=77,installation=48.1,intentRevision=2,windowBitrate=1600000,windowRequests=32,pendingDue=78)
    add(78,'ticketReady',3,limit=4,reservation=77,installation=48.1,intentRevision=2)
    add(79,'highOutput',3,limit=4,reservation=77,installation=78.1,intentRevision=2,width=640)
    events=[dict(attempt=n,elapsed=t,elapsedAfter=t+.1,due=t,positionBefore=t,
        outcome='installed',itemChanged=True,credentialCommitAccepted=True,
        ticketIntentRevision=2,ticketCredentialRevision=0) for n,t in [(2,48),(3,78)]]
    frames=[dict(elapsed=50+i/24,position=50+i/24,frames=1,width=640,generation=0) for i in range(49)]
    return rows,events,frames


class RenewalEvidenceTests(unittest.TestCase):
    def summary(self, rows, events, frames, attempts=3):
        fn=getattr(abr_accesslog,'summarize_policy_v3',None)
        self.assertIsNotNone(fn)
        return fn(rows,expected_attempts=attempts,events=events,frames=frames)

    def test_cooldown_retains_windows_and_renews_only_with_published_frames(self):
        result=self.summary(*trace())
        self.assertEqual((result['attempts'],result['roundLimit'],result['renewals']), (3,4,1))
        self.assertEqual([v['attempt'] for v in result['ticketAuthorities']], [2,3])
        self.assertFalse(result['capabilityAccepted'])

    def test_low_frame_just_before_high_window_does_not_poison_boundary(self):
        rows,events,frames=trace()
        frames.insert(0,dict(elapsed=49.97,position=49.97,frames=1,width=320,generation=0))
        result=self.summary(rows,events,frames)
        self.assertEqual(result['renewals'],1)
        frames[26]['width']=320
        with self.assertRaises(ValueError):self.summary(rows,events,frames)

    def test_high_window_cannot_predate_current_authority_change_sample(self):
        for key,event_key,value in [('intentRevision','ticketIntentRevision',3),
                                    ('credentialRevision','ticketCredentialRevision',1)]:
            rows,events,frames=trace()
            for row in rows[11:]:row[key]=value
            events[-1][event_key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.summary(rows,events,frames)

    def test_v3_contract_mismatches_are_rejected(self):
        mutations=['missing-budget','boolean-limit','refund','early-reservation','invented-install',
            'short-high','few-high','old-high','no-install','bad-window','stale-intent','missing-revision',
            'reset-limit','fifth-attempt','fake-frame','frame-gap','frame-generation','frame-position',
            'bad-cooldown-count','early-ticket','wrong-install-outcome']
        for mutation in mutations:
            rows,events,frames=copy.deepcopy(trace())
            if mutation=='missing-budget':rows[0].pop('budgetVersion')
            elif mutation=='boolean-limit':rows[0]['roundLimit']=True
            elif mutation=='refund':rows[4]['attempts']=0
            elif mutation=='early-reservation':rows[8]['elapsed']=46.9;rows[8]['lastReservation']=46.9;rows[8]['pendingDue']=47.9
            elif mutation=='invented-install':rows[10]['lastInstallation']=48.2
            elif mutation=='short-high':rows[11]['highFrameSeconds']=1.99
            elif mutation=='few-high':rows[11]['highFrameCount']=47
            elif mutation=='old-high':rows[11]['highFrameStart']=48
            elif mutation=='no-install':rows[11]['lastInstallation']=None
            elif mutation=='bad-window':rows[6]['windowRequests']=2
            elif mutation=='stale-intent':rows[6]['intentRevision']=3
            elif mutation=='missing-revision':rows[0].pop('credentialRevision')
            elif mutation=='reset-limit':rows[12]['roundLimit']=2
            elif mutation=='fifth-attempt':rows[-1]['attempts']=5
            elif mutation=='fake-frame':frames=[]
            elif mutation=='frame-gap':frames=frames[:10]+frames[30:]
            elif mutation=='frame-generation':frames[25]['generation']=1
            elif mutation=='frame-position':frames[25]['position']=frames[24]['position']
            elif mutation=='bad-cooldown-count':rows[6]['qualifiedWindows']=1
            elif mutation=='early-ticket':rows[9]['elapsed']=47.9
            else:events[0]['outcome']='cancelled'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):self.summary(rows,events,frames)

    def test_failed_cooldown_window_resets_qualification(self):
        rows,events,frames=trace()
        rows=rows[:7]
        rows.append(dict(rows[-1],elapsed=43,position=43,remaining=77,transfer=43,
            bytes=rows[-1]['bytes']+800000,requests=172,reason='insufficientBandwidth',
            qualifiedWindows=0,windowBitrate=800000,windowRequests=32))
        rows.append(dict(rows[-1],elapsed=47,position=47,remaining=73,transfer=47,
            bytes=rows[-1]['bytes']+800000,requests=188,reason='windowPending',
            windowBitrate=None,windowRequests=None))
        self.summary(rows,[],frames,attempts=1)
        rows[-1].update(reason='reserved',attempts=2,lastReservation=47,pendingDue=48)
        with self.assertRaises(ValueError):self.summary(rows,[],frames,attempts=2)

    def test_total_four_attempts_then_exhausted_and_no_second_renewal(self):
        rows,events,frames=trace()
        base=rows[-1]
        def add(t,reason,attempts,qualified=0,**changes):
            position=79+(t-79)/3
            row=dict(base,elapsed=t,position=position,remaining=120-position,transfer=t,
                bytes=int(t*200000),requests=int(t*4),width=320,reason=reason,
                attempts=attempts,qualifiedWindows=qualified)
            row.update(changes);rows.append(row)
        add(80,'windowStarted',3)
        add(88,'firstQualifiedWindow',3,1,windowBitrate=1600000,windowRequests=32)
        add(96,'cooldown',3,2,windowBitrate=1600000,windowRequests=32)
        add(104,'cooldown',3,2,windowBitrate=1600000,windowRequests=32)
        add(107,'reserved',4,lastReservation=107,pendingDue=108)
        add(108,'ticketReady',4,lastReservation=107)
        add(109,'budgetExhausted',4,lastReservation=107)
        events.append(dict(events[-1],attempt=4,elapsed=108,elapsedAfter=108.1,outcome='preparationFailed'))
        result=self.summary(rows,events,frames,attempts=4)
        self.assertEqual((result['reservations'],result['renewals']),(4,1))
        rows[-1].update(reason='reserved',attempts=5,lastReservation=109,pendingDue=110)
        with self.assertRaises(ValueError):self.summary(rows,events,frames,attempts=5)

    def test_actual_renewal_requires_successful_third_install_and_second_downshift(self):
        decisions,events,frames=trace()
        frames.extend([dict(elapsed=53,position=53,frames=1,width=320,generation=0),
            dict(elapsed=79,position=79,frames=1,width=640,generation=1)])
        policy=self.summary(decisions,events,frames)
        rows=[dict(elapsed=t,sessionId='same',policySamplingVersion=3,productionRecovery=True,
            captureDeviceKind='physical',hostFailureCount=0,automaticAttempts=3,automaticEvents=events) for t in (0,120)]
        result=abr_accesslog.summarize_budget_renewal(rows,frames,decisions,policy)
        self.assertTrue(result['thirdReservationObserved'])
        self.assertFalse(result['physicalOutputVerified'])
        for mutation in ('third-failed','no-low','no-final-high','new-session','revision-change','generation-change','legacy-version'):
            rr,ff,dd=copy.deepcopy((rows,frames,decisions))
            if mutation=='third-failed':rr[-1]['automaticEvents'][-1]['outcome']='preparationFailed'
            elif mutation=='no-low':ff=[f for f in ff if f['width']!=320]
            elif mutation=='no-final-high':ff=ff[:-1]
            elif mutation=='new-session':rr[-1]['sessionId']='new'
            elif mutation=='revision-change':dd[12]['credentialRevision']=1
            elif mutation=='generation-change':dd[12]['generation']=1
            else:rr[-1]['policySamplingVersion']=2
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                abr_accesslog.summarize_budget_renewal(rr,ff,dd,policy)
        from budget_exhaustion import summarize_budget_exhaustion
        with self.assertRaises(ValueError):summarize_budget_exhaustion(rows,frames,decisions)

    def test_v3_pause_command_preserves_cancelled_reservation_and_later_tickets(self):
        marker=dict(sessionId='same',pauseStarted=17,resumeCompleted=19.1,pausePosition=16,
            beforeResumePosition=16,reservationAttempts=1,beforeResumeAttempts=1,
            itemUnchangedBeforeResume=True,installedBeforeResume=False,pauseAcknowledged=True,resumed=True)
        events=[dict(attempt=2,outcome='installed',elapsed=48),dict(attempt=3,outcome='installed',elapsed=78)]
        rows=[dict(elapsed=t,sessionId='same',policySamplingVersion=3,productionCommand='pause-resume',
            productionCommandEvents=marker,automaticAttempts=1 if t<48 else 3,
            automaticEvents=[] if t<48 else events,rate=0,publicPlaybackIntent=False,
            hostStatus='paused',position=16) for t in (17.2,17.6,18,18.4,19,120)]
        policy=dict(reservations=3,tickets=2,attempts=3,ticketAuthorities=[dict(attempt=2),dict(attempt=3)])
        self.assertTrue(abr_accesslog.summarize_production_command(rows,policy)['cancelledReservationPreserved'])
        for mutation in ('refund','missing-ticket','legacy'):
            rr,pp=copy.deepcopy((rows,policy))
            if mutation=='refund':rr[0]['automaticAttempts']=0
            elif mutation=='missing-ticket':pp['ticketAuthorities']=pp['ticketAuthorities'][:1]
            else:
                for r in rr:r['policySamplingVersion']=2
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):abr_accesslog.summarize_production_command(rr,pp)

    def test_renewal_flag_requires_original_production_restrictions(self):
        values=dict(production_recovery=True,physical_device='owned',duration_seconds=120,
            recovery_action='auto-reload',auto_scenario='normal',candidate_preparation='manifest-only',
            require_production_install=True,production_command='pause-resume',require_budget_renewal=True)
        self.assertTrue(abr_accesslog.production_recovery(SimpleNamespace(**values)))
        for change in [dict(require_budget_exhaustion=True),dict(require_production_install=False),
                       dict(production_command='none'),dict(require_budget_renewal=1)]:
            with self.subTest(change=change),self.assertRaises(ValueError):
                abr_accesslog.production_recovery(SimpleNamespace(**dict(values,**change)))


if __name__=='__main__':unittest.main()
