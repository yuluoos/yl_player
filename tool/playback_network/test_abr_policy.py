import unittest
import abr_accesslog


def row(time=9, reason='insufficientBandwidth', attempts=0, **extra):
    return dict(elapsed=time, generation=0, allowed=True, width=320, position=time,
                remaining=120-time, bufferAhead=10, bytes=810000, transfer=9,
                requests=36, overdue=1, reason=reason, attempts=attempts,
                qualifiedWindows=0, sawHigh=True, windowBitrate=720000,
                windowRequests=32, pendingDue=None, **extra)


class PolicyEvidenceTests(unittest.TestCase):
    def summary(self, rows, attempts=0):
        fn = getattr(abr_accesslog, 'summarize_policy', None)
        self.assertIsNotNone(fn)
        return fn(rows, expected_attempts=attempts)

    def test_untriggered_is_not_exercised(self):
        result = self.summary([dict(row(1, 'windowStarted'), bytes=90000, transfer=1, requests=4, windowBitrate=None, windowRequests=None), row()])
        self.assertEqual(result['reasonCounts'], {'windowStarted': 1, 'insufficientBandwidth': 1})
        self.assertEqual(result['attempts'], 0)
        self.assertFalse(result['triggerExercised'])
        self.assertFalse(result['capabilityAccepted'])

    def test_completed_window_rejection_matches_guard_priority_and_threshold(self):
        start = dict(row(1, 'windowStarted'), bytes=0, transfer=1, requests=4,
                     windowBitrate=None, windowRequests=None)
        low = dict(row(), bytes=954999, windowBitrate=954999)
        self.summary([start, low])
        no_progress = dict(low, reason='noProgress', position=1)
        few_requests = dict(low, reason='insufficientRequests', requests=6, windowRequests=2)
        self.summary([start, no_progress])
        self.summary([start, few_requests])
        # An exact-threshold window is qualified, and a higher-priority failed
        # guard cannot be relabelled as a bandwidth problem.
        invalid = [dict(low, bytes=955000, windowBitrate=955000),
                   dict(low, bytes=955001, windowBitrate=955001),
                   dict(low, reason='noProgress'),
                   dict(low, reason='insufficientRequests'),
                   dict(no_progress, reason='insufficientBandwidth'),
                   dict(few_requests, reason='insufficientBandwidth'),
                   dict(few_requests, reason='insufficientRequests', position=1)]
        for sample in invalid:
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                self.summary([start, sample])

    def test_reservation_and_ticket_preserve_frozen_limits(self):
        start = dict(row(1, 'windowStarted'), bytes=200000, transfer=1, requests=4, windowBitrate=None, windowRequests=None)
        first = dict(row(9, 'firstQualifiedWindow'), bytes=1800000, transfer=9, requests=36, windowBitrate=1600000, qualifiedWindows=1)
        a = dict(row(17, 'reserved', 1), bytes=3400000, transfer=17, requests=68, windowBitrate=1600000, pendingDue=17.5)
        b = row(17.5, 'ticketReady', 1); b.update(windowBitrate=None, windowRequests=None)
        r = self.summary([start, first, a, b], 1)
        self.assertEqual(r['reservations'], 1)
        self.assertEqual(r['tickets'], 1)
        self.assertTrue(r['triggerExercised'])
        for field, value in [('windowBitrate', 954999), ('pendingDue', 17.1), ('windowRequests', 2)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.summary([start, first, dict(a, **{field:value}), b], 1)

        for trace in [[a, b], [start, a, b], [start, first, dict(a, elapsed=16), b],
                      [start, first, dict(a, bytes=3300000), b]]:
            with self.subTest(trace=trace), self.assertRaises(ValueError): self.summary(trace, 1)

    def test_intent_revision_rejects_cross_revision_windows_and_tickets(self):
        start = dict(row(1, 'windowStarted'), bytes=200000, transfer=1, requests=4, windowBitrate=None, windowRequests=None, intentRevision=0)
        first = dict(row(9, 'firstQualifiedWindow'), bytes=1800000, transfer=9, requests=36, windowBitrate=1600000, qualifiedWindows=1, intentRevision=0)
        reserved = dict(row(17, 'reserved', 1), bytes=3400000, transfer=17, requests=68, windowBitrate=1600000, pendingDue=17.5, intentRevision=0)
        ticket = dict(row(17.5, 'ticketReady', 1), windowBitrate=None, windowRequests=None, intentRevision=0)
        self.summary([start,first,reserved,ticket],1)
        for index,value in [(0,1),(1,1),(2,1),(3,1),(0,True),(0,-1),(0,2**64),(0,None)]:
            trace=[start,first,reserved,ticket];trace[index]=dict(trace[index],intentRevision=value)
            with self.subTest(index=index,value=value),self.assertRaises(ValueError):self.summary(trace,1)
        with self.assertRaises(ValueError):self.summary([start,{k:v for k,v in first.items() if k!='intentRevision'},reserved,ticket],1)
        restarted=dict(first,reason='windowStarted',qualifiedWindows=0,windowBitrate=None,windowRequests=None,intentRevision=1)
        self.summary([start,restarted])

    def test_credential_revision_rejects_cross_revision_windows_and_tickets(self):
        start = dict(row(1, 'windowStarted'), bytes=200000, transfer=1, requests=4, windowBitrate=None, windowRequests=None, credentialRevision=0)
        first = dict(row(9, 'firstQualifiedWindow'), bytes=1800000, transfer=9, requests=36, windowBitrate=1600000, qualifiedWindows=1, credentialRevision=0)
        reserved = dict(row(17, 'reserved', 1), bytes=3400000, transfer=17, requests=68, windowBitrate=1600000, pendingDue=17.5, credentialRevision=0)
        ticket = dict(row(17.5, 'ticketReady', 1), windowBitrate=None, windowRequests=None, credentialRevision=0)
        self.summary([start,first,reserved,ticket],1)
        for index,value in [(0,1),(1,1),(2,1),(3,1),(0,True),(0,-1),(0,2**64),(0,None)]:
            trace=[start,first,reserved,ticket];trace[index]=dict(trace[index],credentialRevision=value)
            with self.subTest(index=index,value=value),self.assertRaises(ValueError):self.summary(trace,1)
        with self.assertRaises(ValueError):self.summary([start,{k:v for k,v in first.items() if k!='credentialRevision'},reserved,ticket],1)
        restarted=dict(first,reason='windowStarted',qualifiedWindows=0,windowBitrate=None,windowRequests=None,credentialRevision=1)
        self.summary([start,restarted])

    def test_valid_rejections_preserve_invalid_inputs(self):
        for sample in [dict(row(1, 'playbackIneligible'), allowed=False, position=None),
                       dict(row(1, 'nearEnd'), remaining=-0.05),
                       dict(row(1, 'insufficientBuffer'), bufferAhead=-1, position=None),
                       dict(row(1, 'invalidSample'), position=None),
                       dict(row(1, 'invalidSample'), bytes=-1)]:
            with self.subTest(sample=sample):
                self.assertFalse(self.summary([sample])['triggerExercised'])

    def test_ineligible_window_or_ticket_cannot_claim_trigger(self):
        start = dict(row(1, 'windowStarted'), bytes=200000, transfer=1, requests=4, windowBitrate=None, windowRequests=None)
        first = dict(row(9, 'firstQualifiedWindow'), bytes=1800000, transfer=9, requests=36, windowBitrate=1600000, qualifiedWindows=1)
        reserved = dict(row(17, 'reserved', 1), bytes=3400000, transfer=17, requests=68, windowBitrate=1600000, pendingDue=17.5)
        ticket = dict(row(17.5, 'ticketReady', 1), windowBitrate=None, windowRequests=None)
        for field, value in [('allowed', False), ('bufferAhead', 0), ('remaining', 0),
                             ('position', None), ('width', 640), ('sawHigh', False), ('overdue', 0)]:
            for index in range(4):
                trace = [start, first, reserved, ticket]; trace[index] = dict(trace[index], **{field:value})
                with self.subTest(index=index, field=field), self.assertRaises(ValueError): self.summary(trace, 1)
        for reason in ['windowPending', 'backoff']:
            sample = dict(row(2, reason), allowed=False)
            with self.subTest(reason=reason), self.assertRaises(ValueError): self.summary([start, sample])

    def test_invalid_shapes_and_budget_fail_closed(self):
        for rows in [[], [None], [dict(row(), reason='unknown')], [dict(row(), attempts=True)],
                     [dict(row(), elapsed=float('nan'))], [row(10), row(9)], [row(attempts=3)]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError): self.summary(rows)
        with self.assertRaises(ValueError): self.summary([row()], 1)

    def test_trace_version_rejects_unknown_bool_or_mixed_versions(self):
        fn = getattr(abr_accesslog, 'policy_trace_version', None)
        self.assertIsNotNone(fn)
        self.assertIsNone(fn([{}, {}]))
        self.assertEqual(fn([{'policySamplingVersion': 1}] * 2), 1)
        self.assertEqual(fn([{'policySamplingVersion': 2}] * 2), 2)
        self.assertEqual(fn([{'policySamplingVersion': 3}] * 2), 3)
        for rows in [[{'policySamplingVersion': 4}], [{'policySamplingVersion': 1}, {'policySamplingVersion': 2}], [{'policySamplingVersion': True}],
                     [{'policySamplingVersion': 1}, {}], [{'policySamplingVersion': None}]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError): fn(rows)

    def test_v2_policy_requires_credential_and_intent_ticket_binding(self):
        fn=getattr(abr_accesslog,'validate_recovery_authority',None)
        self.assertIsNotNone(fn)
        policy=dict(intentSamples=[dict(elapsed=1,intentRevision=2)],
            credentialSamples=[dict(elapsed=1,credentialRevision=3)],
            ticketAuthorities=[dict(attempt=1,elapsed=17.5,intentRevision=2,credentialRevision=3)])
        event=dict(attempt=1,elapsed=17.51,ticketIntentRevision=2,ticketCredentialRevision=3,outcome='installed',credentialCommitAccepted=True)
        rows=[dict(policySamplingVersion=2,automaticEvents=[event])]
        fn(rows,policy)
        import copy
        for mutation in ['missing-credential','missing-intent','wrong-credential','wrong-intent','missing-event','extra-event','wrong-time','bool-version','missing-fence']:
            rr,pp=copy.deepcopy((rows,policy));e=rr[0]['automaticEvents'][0]
            if mutation=='missing-credential':pp['credentialSamples']=[]
            elif mutation=='missing-intent':pp['intentSamples']=[]
            elif mutation=='wrong-credential':e['ticketCredentialRevision']=4
            elif mutation=='wrong-intent':e['ticketIntentRevision']=3
            elif mutation=='missing-event':rr[0]['automaticEvents']=[]
            elif mutation=='extra-event':rr[0]['automaticEvents'].append(e.copy())
            elif mutation=='wrong-time':e['elapsed']=18
            elif mutation=='missing-fence':e.pop('credentialCommitAccepted')
            else:e['ticketCredentialRevision']=True
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):fn(rr,pp)
        fn([dict(policySamplingVersion=1)],{}) # Historical v1 remains identifiable.

    def test_ticket_without_reservation_is_not_evidence(self):
        with self.assertRaises(ValueError): self.summary([row(20, 'ticketReady', 1)], 1)

if __name__ == '__main__': unittest.main()
