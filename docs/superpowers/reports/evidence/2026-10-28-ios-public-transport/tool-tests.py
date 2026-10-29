from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();at='    def test_public_race_requires_owned_preroll_and_explicit_policy_scenario(self):\n'
t='''    def test_public_transport_race_requires_acknowledged_revision_and_actual_effects(self):
        for scenario in ['pause-during-preparation', 'seek-during-preparation']:
            self.assertTrue(abr_accesslog.public_policy_race(SimpleNamespace(public_policy_race=True,
                duration_seconds=120, recovery_action='auto-reload', candidate_preparation='asset-preroll', auto_scenario=scenario)))
            event=dict(attempt=1, outcome='preparationFailed', due=24.9, elapsed=25,
                warmupStartedElapsed=25.1, warmupDeadlineElapsed=27.1, warmupCompletedElapsed=25.7,
                publicCommandStartedElapsed=25.4, publicCommandCompletedElapsed=25.5, elapsedAfter=25.8,
                publicCommandReady=True, publicCommandApplied=True, publicCommandManuallyInvalidated=False,
                publicCommandItemChanged=False, publicCommandSessionId='same',
                publicCommandIntentBefore=0, publicCommandIntentAfter=1, publicCommandPositionBefore=19,
                publicPausePosition=20, publicSeekTargetMs=20000,
                warmupOutcome='cancelled', warmupStage='waitingReady', warmupDetached=True,
                warmupReusesPrerolledItem=False, warmupOldItemRetained=True)
            resume=dict(applied=True, startedElapsed=27.6, completedElapsed=27.7, pausedElapsed=25.5,
                sessionId='same', itemUnchanged=True, oldTicketAuthorized=False)
            rows=[];frames=[]
            for elapsed in [0,26,26.5,27,28,29,30]:
                paused=scenario.startswith('pause') and 25.5<elapsed<27.6
                position=20 if paused else (max(0,20+elapsed-27.7) if scenario.startswith('pause') else max(0,20+elapsed-25.5))
                rows.append(dict(elapsed=elapsed, autoScenario=scenario, publicPolicyRace=True, publicPolicyCycle=False,
                    sessionId='same', hostFailureCount=0, hostStatus='paused' if paused else 'playing',
                    automaticAttempts=0 if elapsed==0 else 1, automaticEvents=[] if elapsed==0 else [event],
                    publicIntentRevision=0 if elapsed==0 else 1, publicPlaybackIntent=not paused,
                    publicResume=resume if elapsed>=28 else None, rate=0 if paused else 1, position=position,
                    acceptedMaximumWidth=None, acceptedMaximumHeight=None, acceptedMaximumBitrate=None,
                    fixedTrackId=None, peak=0, maximumWidth=0, maximumHeight=0))
                frames.append(dict(elapsed=elapsed+.01, frames=0 if paused else 1,
                    width=0 if paused else 640, position=position))
            policy=dict(attempts=1,reservations=1,tickets=1,triggerExercised=True)
            result=abr_accesslog.summarize_public_transport(rows,frames,policy)
            self.assertTrue(result['oldCandidateRejected']);self.assertFalse(result['capabilityAccepted'])
            for mutation in ['same-revision','replaced-item','expired','budget-refund','missing-command','missing-frames','wrong-effect']:
                rr,ff,pp=copy.deepcopy((rows,frames,policy));e=rr[-1]['automaticEvents'][0]
                if mutation=='same-revision':e['publicCommandIntentAfter']=0
                elif mutation=='replaced-item':e['publicCommandItemChanged']=True
                elif mutation=='expired':e['warmupDeadlineElapsed']=50
                elif mutation=='budget-refund':rr[-1]['automaticAttempts']=0
                elif mutation=='missing-command':e['publicCommandApplied']=False
                elif mutation=='missing-frames':ff=[]
                elif scenario.startswith('pause'):rr[2]['position']=22
                else:ff[-1]['position']=19
                with self.subTest(scenario=scenario,mutation=mutation),self.assertRaises(ValueError):
                    abr_accesslog.summarize_public_transport(rr,ff,pp)

'''
assert at in s;p.write_text(s.replace(at,t+at))
