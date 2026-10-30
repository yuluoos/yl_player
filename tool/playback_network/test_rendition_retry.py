import unittest
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
