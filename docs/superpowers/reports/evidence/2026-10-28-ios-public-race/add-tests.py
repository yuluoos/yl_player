from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();at='    def test_public_policy_cycle_rejects_conflicting_or_short_capture(self):\n'
t='''    def test_public_race_requires_owned_preroll_and_explicit_policy_scenario(self):
        values = dict(public_policy_race=True, public_policy_cycle=False, duration_seconds=120,
            direct_hls_control=False, recovery_action='auto-reload',
            auto_scenario='caps-during-preparation', candidate_preparation='asset-preroll', startup_delay_ms=0)
        self.assertTrue(abr_accesslog.public_policy_race(SimpleNamespace(**values)))
        self.assertFalse(abr_accesslog.public_policy_race(SimpleNamespace()))
        for key, value in [('public_policy_race', 1), ('public_policy_cycle', True),
                           ('duration_seconds', 40), ('direct_hls_control', True),
                           ('recovery_action', 'none'), ('auto_scenario', 'normal'),
                           ('candidate_preparation', 'manifest-only'), ('startup_delay_ms', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                abr_accesslog.public_policy_race(SimpleNamespace(**dict(values, **{key: value})))

    def test_public_race_requires_actual_candidate_command_cancellation_and_retained_policy(self):
        for scenario in ['caps-during-preparation', 'fixed-during-preparation']:
            fixed = 'dash-video-w320-h180-b350000' if scenario.startswith('fixed') else None
            width = None if fixed else 320
            event = dict(attempt=1, outcome='preparationFailed', elapsed=25, due=24.9,
                elapsedAfter=26, warmupOutcome='cancelled', warmupStage='waitingReady',
                warmupDetached=True, warmupReusesPrerolledItem=False,
                publicCommandStartedElapsed=25.5, publicCommandCompletedElapsed=25.8,
                publicCommandApplied=True, publicCommandSessionId='same',
                publicCommandItemChanged=True, publicCommandReady=True,
                publicCommandManuallyInvalidated=False, warmupOldItemRetained=False)
            rows = [dict(elapsed=t, publicPolicyRace=True, publicPolicyCycle=False,
                autoScenario=scenario, sessionId='same', hostFailureCount=0, hostStatus='playing',
                acceptedMaximumWidth=width if t>26 else None, acceptedMaximumHeight=None,
                acceptedMaximumBitrate=None, fixedTrackId=fixed if t>26 else None,
                maximumWidth=(width or 0) if t>26 else 0,
                maximumHeight=100000 if width and t>26 else 0, peak=0,
                automaticAttempts=1 if t>24 else 0, automaticEvents=[event] if t>26 else [])
                for t in [0, 27, 28, 29, 30]]
            frames = [dict(elapsed=t+.1, frames=1, width=320) for t in [27,28,29,30]]
            policy = dict(reservations=1, tickets=1, attempts=1, triggerExercised=True)
            result = abr_accesslog.summarize_public_race(rows, frames, policy)
            self.assertFalse(result['capabilityAccepted'])
            self.assertTrue(result['oldCandidateRejected'])
            mutations = ['zero-ticket','manual-invalidation','failed-command','not-ready','same-item',
                'not-cancelled','installed','new-session','wrong-policy','high-frame','no-frames',
                'refunded-budget','failed-state','missing-final-event','nan-time','reversed-time']
            for mutation in mutations:
                rr, ff, pp = copy.deepcopy((rows, frames, policy))
                ee=rr[-1]['automaticEvents'][0]
                if mutation=='zero-ticket': pp['tickets']=0
                elif mutation=='manual-invalidation': ee['publicCommandManuallyInvalidated']=True
                elif mutation=='failed-command': ee['publicCommandApplied']=False
                elif mutation=='not-ready': ee['publicCommandReady']=False
                elif mutation=='same-item': ee['publicCommandItemChanged']=False
                elif mutation=='not-cancelled': ee['warmupOutcome']='ready'
                elif mutation=='installed': ee['outcome']='installed'
                elif mutation=='new-session': rr[-1]['sessionId']='other'
                elif mutation=='wrong-policy': rr[-1]['acceptedMaximumWidth']=999
                elif mutation=='high-frame': ff[-1]['width']=640
                elif mutation=='no-frames': ff=[]
                elif mutation=='refunded-budget': rr[-1]['automaticAttempts']=0
                elif mutation=='failed-state': rr[-1]['hostStatus']='failed'
                elif mutation=='missing-final-event': rr[-1]['automaticEvents']=[]
                elif mutation=='nan-time': ee['publicCommandCompletedElapsed']=float('nan')
                elif mutation=='reversed-time': ee['publicCommandCompletedElapsed']=24
                with self.subTest(scenario=scenario, mutation=mutation), self.assertRaises(ValueError):
                    abr_accesslog.summarize_public_race(rr, ff, pp)

'''
assert at in s;p.write_text(s.replace(at,t+at))
