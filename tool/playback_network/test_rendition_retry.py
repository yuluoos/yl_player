import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import rendition_retry
import test_proxy_boundaries as boundaries
import test_transaction_metrics as metrics
try:
    from rendition_retry import summarize_rendition_retries
except ImportError:
    summarize_rendition_retries = None


class RenditionRetryTests(unittest.TestCase):
    def fixture(self):
        base=boundaries.ProxyBoundaryTests();base.setUp()
        failed=dict(base.trace,version=7,resourceToken='a'*64,metrics=None,outcome=1,
            taskOutcome=1,downstreamTerminal=10.33,taskComplete=10.33,cancelCause=3,
            cancelSource=1,cancelErrorDomain=1,cancelErrorCode=54)
        return failed,base.server

    def request(self,ident,admission,proxy=None,asset='high2.m4s'):
        b,s=self.fixture()
        b.update(requestID=ident,serverRequestID=ident,admission=admission,terminal=admission+.4,
            response=admission+.1,firstBody=admission+.11,lastBody=admission+.2,
            firstSend=admission+.1,lastSend=admission+.2,lastSendComplete=admission+.3,
            upstreamComplete=admission+.31,downstreamTerminal=admission+.4,taskComplete=admission+.32,
            outcome=0,taskOutcome=0,cancelCause=0,cancelSource=0,cancelErrorDomain=0,cancelErrorCode=0,
            metrics=metrics.DurationStateTests().source())
        if proxy:b['proxyID']=proxy
        return b,dict(s,requestId=ident,asset=asset)

    def test_only_admissions_after_error_are_retries_not_already_inflight_requests(self):
        self.assertIsNotNone(summarize_rendition_retries)
        b,s=self.fixture();s['asset']='high1.m4s'
        queued,qs=self.request(2,10.1)
        equal,es=self.request(3,10.33)
        later,ls=self.request(4,10.5,asset='high1.m4s')
        result=summarize_rendition_retries([b,queued,equal,later],[s,qs,es,ls],{'high1.m4s','high2.m4s'})
        row=result['highResets'][0]
        self.assertEqual(row['sameProxyLaterHighRequests'],[4])
        self.assertEqual(row['sameProxySameAssetRetries'],[4])
        self.assertEqual(row['sameProxyOutstandingHighRequests'],[2,3])
        self.assertFalse(result['rootCauseEstablished']);self.assertFalse(result['capabilityAccepted'])

    def test_replacement_proxy_is_separate_and_server_clock_shift_does_not_change_retry_order(self):
        self.assertIsNotNone(summarize_rendition_retries)
        b,s=self.fixture();s['asset']='high1.m4s'
        later,ls=self.request(2,10.5,'87654321-1234-1234-1234-123456789abc')
        result=summarize_rendition_retries([b,later],[s,ls],{'high1.m4s','high2.m4s'})
        row=result['highResets'][0]
        self.assertEqual(row['sameProxyLaterHighRequests'],[])
        self.assertEqual(row['otherProxyLaterHighRequests'],[dict(proxyID='87654321-1234-1234-1234-123456789abc',requestID=2)])
        shifted=[dict(v,startMs=v['startMs']+1e8,endMs=v['endMs']+1e8) for v in (s,ls)]
        self.assertEqual(result,summarize_rendition_retries([b,later],shifted,{'high1.m4s','high2.m4s'}))

    def test_missing_correlation_and_legacy_source_cannot_be_called_no_retry(self):
        self.assertIsNotNone(summarize_rendition_retries)
        b,s=self.fixture();s['asset']='high1.m4s'
        b.pop('serverRequestID')
        with self.assertRaises(ValueError):summarize_rendition_retries([b],[s],{'high1.m4s'})
        b['serverRequestID']=7;b['version']=6
        for k in ['cancelSource','cancelErrorDomain','cancelErrorCode']:b.pop(k)
        with self.assertRaises(ValueError):summarize_rendition_retries([b],[s],{'high1.m4s'})


class ScopedRenditionRetryTests(unittest.TestCase):
    def fixture(self):
        helper = RenditionRetryTests()
        failed, server = helper.fixture()
        server['asset'] = 'high1.m4s'
        retired = dict(failed, proxyID='87654321-1234-1234-1234-123456789abc',
            cancelCause=1, cancelSource=0, cancelErrorDomain=0, cancelErrorCode=0)
        retired.pop('serverRequestID')
        return helper, failed, server, retired

    def summarize(self, rows, servers):
        return rendition_retry.summarize_scoped_rendition_retries(rows, servers, {'high1.m4s', 'high2.m4s'})

    def test_retired_unjoined_request_does_not_hide_another_proxy_retry(self):
        helper, failed, server, retired = self.fixture()
        later, later_server = helper.request(2, 10.5, asset='high1.m4s')
        result = self.summarize([retired, failed, later], [server, later_server])
        self.assertFalse(result['fullyCorrelated'])
        self.assertFalse(result['capabilityAccepted'])
        old, current = result['proxyScopes']
        self.assertIsNone(old['highResets'])
        self.assertEqual(old['uncorrelatedRequests'][0]['requestID'], 1)
        self.assertEqual(old['uncorrelatedRequests'][0]['cancelCause'], 1)
        self.assertEqual(current['highResets'][0]['sameProxySameAssetRetries'], [2])
        self.assertNotIn('otherProxyLaterHighRequests', current['highResets'][0])
        with self.assertRaises(ValueError):
            summarize_rendition_retries([retired, failed, later], [server, later_server], {'high1.m4s'})

    def test_same_proxy_unknown_or_unmatched_server_prevents_absence_claim(self):
        _, failed, server, retired = self.fixture()
        retired.update(proxyID=failed['proxyID'], requestID=2)
        for rows, servers in [([failed, retired], [server]),
                              ([failed], [server, dict(server, requestId=8)])]:
            with self.subTest(rows=len(rows)):
                result = self.summarize(rows, servers)
                self.assertFalse(result['proxyScopes'][0]['retryObservationComplete'])
                self.assertIsNone(result['proxyScopes'][0]['highResets'])

    def test_complete_scope_preserves_same_device_order_and_excludes_replacements(self):
        helper, failed, server, retired = self.fixture()
        later, later_server = helper.request(2, 10.5, retired['proxyID'])
        result = self.summarize([failed, later], [server, later_server])
        self.assertTrue(result['fullyCorrelated'])
        self.assertEqual(result['proxyScopes'][0]['highResets'][0]['sameProxyLaterHighRequests'], [])
        shifted = [dict(s, startMs=s['startMs']+1e8, endMs=s['endMs']+1e8) for s in [server,later_server]]
        self.assertEqual(result, self.summarize([failed,later], shifted))

    def test_corrupt_unjoined_row_and_legacy_version_are_still_rejected(self):
        _, failed, server, retired = self.fixture()
        for bad in [dict(retired, terminal=0), dict(retired, version=6)]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.summarize([failed,bad], [server])

    def test_cli_reads_plain_or_compressed_capture_and_keeps_global_failure(self):
        _, failed, server, retired = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root/'high-assets.json'
            assets.write_text(json.dumps(['high1.m4s']))
            for suffix, opener in [('.jsonl', open), ('.jsonl.gz', gzip.open)]:
                with self.subTest(suffix=suffix):
                    paths = [root/('proxy'+suffix), root/('server'+suffix)]
                    for path, rows in zip(paths, [[failed,retired],[server]]):
                        with opener(path, 'wt') as stream:
                            stream.write(''.join(json.dumps(row)+'\n' for row in rows))
                    result = subprocess.run([sys.executable, '-B', rendition_retry.__file__,
                        '--boundaries', str(paths[0]), '--server-requests', str(paths[1]),
                        '--high-assets', str(assets), '--scoped'], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    observation = json.loads(result.stdout)
                    self.assertFalse(observation['fullyCorrelated'])
                    self.assertFalse(observation['capabilityAccepted'])
