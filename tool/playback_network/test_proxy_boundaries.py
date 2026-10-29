import copy
import unittest
try:
    from proxy_boundaries import summarize_proxy_boundaries
except ImportError:
    summarize_proxy_boundaries = None


class ProxyBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(summarize_proxy_boundaries)
        self.trace = dict(version=1, proxyID='12345678-1234-1234-1234-123456789abc',
            requestID=1, serverRequestID=7, admission=10, response=10.2,
            firstBody=10.21, lastBody=10.3, firstSend=10.2, lastSend=10.3,
            lastSendComplete=10.31, upstreamComplete=10.32, terminal=10.33,
            bodyBytes=4096, sentBodyBytes=4096, bodyCallbacks=2, sendCount=3,
            sendCompletions=3, sendFailures=0, sendWaitSum=.02, sendWaitMax=.01,
            httpStatus=200, outcome=0)
        self.server = dict(requestId=7, asset='network-period-0/chunk-0-00001.m4s',
            startMs=5000, endMs=5100, bodyBytesWritten=4096, status=200,
            outcome='complete', method='GET')

    def test_join_uses_request_identity_and_durations_not_cross_clock_offsets(self):
        result = summarize_proxy_boundaries([self.trace], [self.server])
        self.assertTrue(result['fullyCorrelated'])
        row = result['requests'][0]
        self.assertAlmostEqual(row['upstreamSeconds'], .32)
        self.assertAlmostEqual(row['serverSeconds'], .1)
        self.assertAlmostEqual(row['upstreamMinusServerSeconds'], .22)
        self.assertAlmostEqual(row['responseWaitSeconds'], .2)
        self.assertAlmostEqual(row['sendWaitSumSeconds'], .02)
        shifted = dict(self.server, startMs=20000, endMs=20100)
        self.assertEqual(row, summarize_proxy_boundaries([self.trace], [shifted])['requests'][0])
        self.assertFalse(result['physicalOutputVerified'])
        self.assertFalse(result['capabilityAccepted'])

    def test_cancelled_unbound_request_remains_partial_not_success(self):
        row={k:v for k,v in self.trace.items() if k not in ('response','serverRequestID','httpStatus','upstreamComplete','lastSendComplete')}
        row.update(outcome=1, sentBodyBytes=0, sendCompletions=0)
        result=summarize_proxy_boundaries([row],[self.server])
        self.assertEqual(result['outcomeCounts'], {'cancelled':1})
        self.assertFalse(result['fullyCorrelated'])
        self.assertEqual(result['unmatchedServerRequestIDs'],[7])
        self.assertIsNone(result['requests'][0]['upstreamSeconds'])

    def test_missing_duplicate_or_malformed_complete_evidence_is_rejected(self):
        invalid=[dict(self.trace, terminal=10),dict(self.trace, bodyBytes=4095),
            dict(self.trace, sendCompletions=2),dict(self.trace, sentBodyBytes=1),
            dict(self.trace, response=float('nan')),dict(self.trace, outcome=True),
            dict(self.trace, url='https://secret'),dict(self.trace, serverRequestID=8),
            {k:v for k,v in self.trace.items() if k!='upstreamComplete'},
            {k:v for k,v in self.trace.items() if k!='serverRequestID'}]
        for row in invalid:
            with self.subTest(row=row),self.assertRaises(ValueError):
                summarize_proxy_boundaries([row],[self.server])
        for rows in [[],[self.trace,self.trace], [self.trace,dict(self.trace,requestID=2)]]:
            with self.subTest(rows=rows),self.assertRaises(ValueError):
                summarize_proxy_boundaries(rows,[self.server])

    def test_unmatched_media_is_reported_and_manifest_is_not_proxy_traffic(self):
        extra=dict(self.server,requestId=8)
        manifest=dict(self.server,requestId=9,asset='manifest.mpd')
        result=summarize_proxy_boundaries([self.trace],[self.server,extra,manifest])
        self.assertEqual(result['unmatchedServerRequestIDs'],[8])
        self.assertFalse(result['fullyCorrelated'])

    def test_cancelled_pending_body_can_follow_completed_header_send(self):
        row = dict(self.trace, outcome=1, lastSend=10.3, lastSendComplete=10.21,
                   sendCount=2, sendCompletions=1, sentBodyBytes=0)
        result = summarize_proxy_boundaries([row], [self.server])
        self.assertEqual(result['outcomeCounts'], {'cancelled':1})

    def test_request_correlation_survives_cancellation_before_response(self):
        token='87654321-1234-1234-1234-123456789abc'
        row={k:v for k,v in self.trace.items() if k not in ('response','serverRequestID','httpStatus','upstreamComplete','lastSendComplete','firstBody','lastBody','firstSend','lastSend')}
        row.update(correlationID=token,outcome=1,bodyBytes=0,bodyCallbacks=0,sentBodyBytes=0,sendCount=0,sendCompletions=0)
        result=summarize_proxy_boundaries([row],[dict(self.server,proxyTraceID=token)])
        self.assertTrue(result['fullyCorrelated'])
        self.assertEqual(result['requests'][0]['serverRequestID'],7)

    def test_partial_diagnostic_is_preserved_but_receipt_gets_failure(self):
        from proxy_boundaries import record_proxy_observation
        receipt={'errors':['existing failure']}
        record_proxy_observation(receipt,[self.trace],[self.server,dict(self.server,requestId=8)])
        self.assertEqual(receipt['errors'],['existing failure','proxy request correlation incomplete'])
        self.assertFalse(receipt['proxyRequestObservation']['fullyCorrelated'])
        complete={'errors':[]}; record_proxy_observation(complete,[self.trace],[self.server])
        self.assertEqual(complete['errors'],[])

    def test_input_is_preserved_and_failed_send_does_not_claim_all_bytes(self):
        row=dict(self.trace,outcome=2,sendFailures=1,sentBodyBytes=2048)
        before=copy.deepcopy(row)
        result=summarize_proxy_boundaries([row],[self.server])
        self.assertEqual(row,before)
        self.assertEqual(result['outcomeCounts'],{'sendFailed':1})

class ProxyVersionTests(unittest.TestCase):
    def test_versions_fail_closed_and_legacy_is_explicit(self):
        from proxy_boundaries import proxy_trace_version
        self.assertIsNone(proxy_trace_version([{}]))
        self.assertEqual(proxy_trace_version([{'proxyRequestSamplingVersion':1}]),1)
        for rows in [[{'proxyRequestSamplingVersion':True}],
                     [{'proxyRequestSamplingVersion':4}],
                     [{'proxyRequestSamplingVersion':1},{}]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError): proxy_trace_version(rows)

    def test_v2_metrics_required_and_bound_to_probe_version(self):
        from transaction_metrics import summarize_transactions
        from test_transaction_metrics import metrics
        from proxy_boundaries import proxy_trace_version
        self.assertEqual(proxy_trace_version([{'proxyRequestSamplingVersion':2}]),2)
        fixture=ProxyBoundaryTests();fixture.setUp()
        self.trace=fixture.trace;self.server=fixture.server
        row=dict(self.trace,version=2,metrics=metrics())
        self.assertTrue(summarize_proxy_boundaries([row],[self.server],2)['requests'][0]['transactionMetrics']['complete'])
        for data,version in [(row,1),(dict(row,metrics=None),2),(self.trace,2)]:
            with self.assertRaises(ValueError):summarize_proxy_boundaries([data],[self.server],version)


class ProxyDateStateTests(unittest.TestCase):
    def test_v3_requires_date_states_and_preserves_partial_failure_gate(self):
        from proxy_boundaries import proxy_trace_version
        from test_transaction_metrics import DurationStateTests,metrics
        fixture=ProxyBoundaryTests();fixture.setUp()
        self.assertEqual(proxy_trace_version([dict(proxyRequestSamplingVersion=3)]),3)
        row=dict(fixture.trace,version=3,metrics=DurationStateTests().source())
        self.assertTrue(summarize_proxy_boundaries([row],[fixture.server],3)['requests'][0]['transactionMetrics']['complete'])
        for value in [metrics(),None]:
            with self.assertRaises(ValueError):summarize_proxy_boundaries([dict(row,metrics=value)],[fixture.server],3)
        early=copy.deepcopy(row['metrics']['transactions'][0])
        for k,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:early[k]=None;early['durationStates'][k]=state
        row['metrics'].update(transactionCount=2,transactions=[early,row['metrics']['transactions'][0]])
        with self.assertRaises(ValueError):summarize_proxy_boundaries([row],[fixture.server],3)
        row['outcome']=1
        self.assertFalse(summarize_proxy_boundaries([row],[fixture.server],3)['requests'][0]['transactionMetrics']['complete'])
