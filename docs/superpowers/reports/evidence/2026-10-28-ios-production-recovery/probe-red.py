from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();i=s.index('    def test_candidate_preparation')
s=s[:i]+'''    def test_production_recovery_requires_physical_public_normal_capture(self):
        values = dict(production_recovery=True, physical_device='00008140-000C49CC3493001C',
            duration_seconds=120, recovery_action='auto-reload', candidate_preparation='manifest-only',
            auto_scenario='normal', public_policy_cycle=False, public_policy_race=False, direct_hls_control=False,
            startup_delay_ms=0)
        self.assertTrue(abr_accesslog.production_recovery(SimpleNamespace(**values)))
        self.assertFalse(abr_accesslog.production_recovery(SimpleNamespace()))
        for key, value in [('physical_device', None), ('duration_seconds', 40), ('recovery_action', 'none'),
                           ('auto_scenario', 'pause-first'), ('candidate_preparation', 'asset-preroll'),
                           ('public_policy_cycle', True), ('public_policy_race', True), ('direct_hls_control', True),
                           ('startup_delay_ms', 1), ('production_recovery', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                abr_accesslog.production_recovery(SimpleNamespace(**dict(values, **{key: value})))

    def test_production_recovery_requires_real_public_install_and_high_frames(self):
        event = dict(outcome='installed', elapsedAfter=20, itemChanged=True, credentialCommitAccepted=True)
        rows = [dict(elapsed=0, productionRecovery=True, captureDeviceKind='physical', sessionId='same',
                     publicPolicyRace=False, publicPolicyCycle=False, hostFailureCount=0, width=640, automaticEvents=[]),
                dict(elapsed=10, productionRecovery=True, captureDeviceKind='physical', sessionId='same',
                     publicPolicyRace=False, publicPolicyCycle=False, hostFailureCount=0, width=320, automaticEvents=[]),
                dict(elapsed=120, productionRecovery=True, captureDeviceKind='physical', sessionId='same',
                     publicPolicyRace=False, publicPolicyCycle=False, hostFailureCount=0, width=640, automaticEvents=[event])]
        frames = [dict(elapsed=21, width=640, frames=1)]
        result = abr_accesslog.summarize_production_recovery(rows, frames)
        self.assertEqual(result['installed'], 1)
        self.assertFalse(result['capabilityAccepted'])
        for mutation in ['wrong-mode', 'no-session', 'changed-session', 'host-failure', 'no-high', 'stale-high', 'no-install', 'credential']:
            rr, ff = copy.deepcopy((rows, frames))
            if mutation=='wrong-mode':rr[0]['productionRecovery']=False
            elif mutation=='no-session':rr[0]['sessionId']=None
            elif mutation=='changed-session':rr[-1]['sessionId']='other'
            elif mutation=='host-failure':rr[-1]['hostFailureCount']=1
            elif mutation=='no-high':ff[0]['width']=320
            elif mutation=='stale-high':ff[0]['elapsed']=19
            elif mutation=='no-install':rr[-1]['automaticEvents'][0]['itemChanged']=False
            else:rr[-1]['automaticEvents'][0]['credentialCommitAccepted']=False
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                abr_accesslog.summarize_production_recovery(rr, ff)

'''+s[i:];p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();i=s.index('def policy_trace_version');s=s[:i]+'''def production_recovery(args):
    return False


def summarize_production_recovery(rows, frames):
    return dict(installed=0, capabilityAccepted=False)


'''+s[i:];p.write_text(s)
