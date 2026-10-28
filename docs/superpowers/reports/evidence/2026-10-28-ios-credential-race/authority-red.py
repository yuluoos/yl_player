from pathlib import Path
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text();marker='    def test_ticket_without_reservation_is_not_evidence(self):'
t='''    def test_v2_policy_requires_credential_and_intent_ticket_binding(self):
        fn=getattr(abr_accesslog,'validate_recovery_authority',None)
        self.assertIsNotNone(fn)
        policy=dict(intentSamples=[dict(elapsed=1,intentRevision=2)],
            credentialSamples=[dict(elapsed=1,credentialRevision=3)],
            ticketAuthorities=[dict(attempt=1,elapsed=17.5,intentRevision=2,credentialRevision=3)])
        event=dict(attempt=1,elapsed=17.51,ticketIntentRevision=2,ticketCredentialRevision=3)
        rows=[dict(policySamplingVersion=2,automaticEvents=[event])]
        fn(rows,policy)
        import copy
        for mutation in ['missing-credential','missing-intent','wrong-credential','wrong-intent','missing-event','extra-event','wrong-time','bool-version']:
            rr,pp=copy.deepcopy((rows,policy));e=rr[0]['automaticEvents'][0]
            if mutation=='missing-credential':pp['credentialSamples']=[]
            elif mutation=='missing-intent':pp['intentSamples']=[]
            elif mutation=='wrong-credential':e['ticketCredentialRevision']=4
            elif mutation=='wrong-intent':e['ticketIntentRevision']=3
            elif mutation=='missing-event':rr[0]['automaticEvents']=[]
            elif mutation=='extra-event':rr[0]['automaticEvents'].append(e.copy())
            elif mutation=='wrong-time':e['elapsed']=18
            else:e['ticketCredentialRevision']=True
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):fn(rr,pp)
        fn([dict(policySamplingVersion=1)],{}) # Historical v1 remains identifiable.

''';assert marker in s;s=s.replace(marker,t+marker);p.write_text(s)
