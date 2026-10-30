import copy
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import test_proxy_boundaries as fixtures
import test_transaction_metrics as metric_fixtures
from proxy_boundaries import IncompleteSuccessfulTransactions, summarize_proxy_boundaries
try:
    from request_attribution import summarize_request_attribution
except ImportError:
    summarize_request_attribution = None


def evidence():
    row, server = fixtures.ProxyLoopbackErrorSourceTests().source()
    row.update(outcome=0, taskOutcome=0, cancelCause=0, cancelSource=0,
               cancelErrorDomain=0, cancelErrorCode=0, serverRequestID=1,
               correlationID='87654321-1234-1234-1234-123456789abc')
    metric = metric_fixtures.DurationStateTests().source()
    metric['version'] = 3
    metric['transactions'][0]['transportBytes'] = dict(requestHeaders=300,
        requestBody=0, responseHeaders=100, responseBody=4096)
    early = copy.deepcopy(metric['transactions'][0])
    for key, state in [('fetchSeconds', 2), ('responseWaitSeconds', 2), ('responseSeconds', 3)]:
        early[key] = None; early['durationStates'][key] = state
    early['transportBytes'].update(responseHeaders=0, responseBody=0)
    metric.update(transactionCount=2, transactions=[early, metric['transactions'][0]])
    row['metrics'] = metric
    server.update(requestId=1, connectionId=1, connectionRequestIndex=1,
                  proxyTraceID=row['correlationID'])
    life = dict(version=1, acceptedCount=1, rejectedCount=0, droppedRejections=0,
        rejections=[], connections=[dict(connectionId=1, acceptedSeconds=0,
            closedSeconds=1, activeAtAdmission=1, requestIds=[1],
            unrecordedRequests=0, closeReason='handlerEnded')])
    return [row], [server], life


class RequestAttributionTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(summarize_request_attribution)

    def test_partial_earlier_transaction_keeps_final_timing_without_changing_strict_gate(self):
        rows, servers, life = evidence(); before = copy.deepcopy((rows, servers, life))
        result = summarize_request_attribution(rows, servers, life)
        request = result['requests'][0]
        self.assertEqual(request['serverReceipt'], 'parsed-request-observed')
        self.assertEqual(request['transactions'][0]['timingState'], 'request-recorded-response-unobserved')
        self.assertIsNone(request['transactions'][0]['durations']['fetchSeconds'])
        self.assertTrue(request['finalTransactionTimingComplete'])
        self.assertFalse(request['allTransactionTimingsComplete'])
        self.assertIsNone(request['transactions'][0]['serverRequestID'])
        self.assertIsNone(request['transactions'][1]['serverRequestID'])
        self.assertFalse(result['strictProxyEvidencePassed'])
        self.assertEqual(result['strictFailures'][0]['code'], 'incomplete-successful-transactions')
        self.assertEqual((rows, servers, life), before)
        with self.assertRaises(IncompleteSuccessfulTransactions):
            summarize_proxy_boundaries(rows, servers)

    def test_cancelled_unknown_is_not_joined_by_same_resource_or_zero_counts(self):
        rows, servers, life = evidence()
        cancelled = copy.deepcopy(rows[0])
        for key in ('serverRequestID', 'response', 'httpStatus', 'upstreamComplete',
                    'firstBody', 'lastBody', 'firstSend', 'lastSend', 'lastSendComplete'):
            cancelled.pop(key)
        cancelled.update(requestID=2, correlationID='abcdef12-1234-1234-1234-123456789abc',
            outcome=1, taskOutcome=1, cancelCause=1, bodyBytes=0, sentBodyBytes=0,
            bodyCallbacks=0, sendCount=0, sendCompletions=0, sendWaitSum=0, sendWaitMax=0)
        metric = cancelled['metrics']; metric.update(transactionCount=1, transactions=metric['transactions'][:1])
        item = metric['transactions'][0]
        for key, state in [('fetchToRequestSeconds', 2), ('requestSeconds', 3), ('responseWaitSeconds', 3)]:
            item[key] = None; item['durationStates'][key] = state
        item['transportBytes']['requestHeaders'] = 0
        result = summarize_request_attribution(rows+[cancelled], servers, life)
        request = result['requests'][1]
        self.assertEqual(request['serverReceipt'], 'not-observed-in-recorded-requests')
        self.assertIsNone(request['serverRequestID'])
        self.assertEqual(request['transactions'][0]['timingState'], 'before-recorded-request')
        self.assertEqual(request['cancelCause'], 1)
        self.assertEqual(request['physicalReceipt'], 'unknown')
        self.assertTrue(result['serverCoverage']['allAcceptedConnectionsHaveParsedRequests'])
        self.assertFalse(result['strictProxyEvidencePassed'])

    def test_unparsed_connection_remains_unassigned_and_unclosed_log_is_incomplete(self):
        rows, servers, life = evidence()
        life['acceptedCount'] = 2
        life['connections'].append(dict(life['connections'][0], connectionId=2, requestIds=[]))
        result = summarize_request_attribution(rows, servers, life)
        self.assertEqual(result['serverCoverage']['withoutParsedRequest'], [2])
        self.assertFalse(result['serverCoverage']['allAcceptedConnectionsHaveParsedRequests'])
        life['connections'][1].update(closedSeconds=None, closeReason=None)
        self.assertFalse(summarize_request_attribution(rows, servers, life)['serverCoverage']['complete'])

    def test_missing_empty_legacy_and_truncated_metrics_are_not_complete(self):
        for kind in ('missing', 'empty', 'legacy', 'truncated'):
            rows, servers, life = evidence(); rows[0].update(outcome=1, taskOutcome=1, cancelCause=1)
            if kind == 'missing': rows[0]['metrics'] = None
            elif kind == 'empty': rows[0]['metrics'].update(transactionCount=0, transactions=[])
            elif kind == 'legacy': rows[0]['metrics'] = metric_fixtures.DurationStateTests().source()
            else: rows[0]['metrics'].update(transactionCount=33, truncated=1,
                transactions=rows[0]['metrics']['transactions'][1:]*32)
            request = summarize_request_attribution(rows, servers, life)['requests'][0]
            self.assertEqual(request['metricAvailability'],
                {'missing':'unavailable', 'empty':'no-transactions', 'legacy':'legacy', 'truncated':'truncated'}[kind])
            if kind != 'legacy': self.assertFalse(request['allTransactionTimingsComplete'])
            if kind == 'truncated': self.assertIsNone(request['finalTransactionTimingComplete'])

    def test_corrupt_evidence_is_rejected_and_separate_clock_offsets_do_not_assign_transactions(self):
        rows, servers, life = evidence(); expected = summarize_request_attribution(rows, servers, life)
        servers[0].update(startMs=20000, endMs=20100)
        self.assertEqual(expected, summarize_request_attribution(rows, servers, life))
        rows[0]['metrics']['transactions'][0]['durationStates']['responseSeconds'] = 0
        with self.assertRaises(ValueError): summarize_request_attribution(rows, servers, life)
        rows, servers, life = evidence(); life['connections'][0]['requestIds'] = []
        with self.assertRaises(ValueError): summarize_request_attribution(rows, servers, life)

    def test_cli_reads_gzip_and_marks_diagnostic_not_acceptance(self):
        rows, servers, life = evidence()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in [('proxy', rows), ('server', servers)]:
                (root/(name+'.jsonl.gz')).write_bytes(gzip.compress(('\n'.join(map(json.dumps, value))+'\n').encode()))
            (root/'lifecycle.json').write_text(json.dumps(life))
            run = subprocess.run([sys.executable, str(Path(__file__).with_name('request_attribution.py')),
                '--boundaries', str(root/'proxy.jsonl.gz'), '--server-requests', str(root/'server.jsonl.gz'),
                '--lifecycle', str(root/'lifecycle.json')], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout)
        self.assertTrue(result['diagnosticOnly']); self.assertFalse(result['capabilityAccepted'])
        self.assertFalse(result['strictProxyEvidencePassed'])
