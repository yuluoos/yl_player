import copy
import unittest
try:
    from connection_lifecycle import summarize_lifecycle
except ImportError:
    summarize_lifecycle=None


def evidence():
    return dict(version=1,acceptedCount=2,rejectedCount=0,droppedRejections=0,rejections=[],connections=[
        dict(connectionId=1,acceptedSeconds=0,closedSeconds=.1,activeAtAdmission=1,requestIds=[],unrecordedRequests=0,closeReason='handlerEnded'),
        dict(connectionId=2,acceptedSeconds=.2,closedSeconds=.5,activeAtAdmission=1,requestIds=[1],unrecordedRequests=0,closeReason='handlerEnded')]),[dict(connectionId=2,requestId=1,connectionRequestIndex=1)]


class LifecycleTests(unittest.TestCase):
    def setUp(self):self.assertIsNotNone(summarize_lifecycle,'connection lifecycle validator missing')
    def test_preserves_unparsed_connections_without_claiming_network_cause(self):
        result=summarize_lifecycle(*evidence())
        self.assertEqual(result['withoutParsedRequest'],[1]);self.assertTrue(result['complete'])
        self.assertFalse(result['retryCauseProven']);self.assertFalse(result['capabilityAccepted'])
    def test_rejects_corrupt_or_unbound_request_and_timing_records(self):
        for kind in ['count','id','request','index','closed','time','reason','secret','bool','duplicate','missing']:
            trace,rows=evidence()
            if kind=='count':trace['acceptedCount']=1
            elif kind=='id':trace['connections'][1]['connectionId']=1
            elif kind=='request':trace['connections'][1]['requestIds']=[2]
            elif kind=='index':rows[0]['connectionRequestIndex']=2
            elif kind=='closed':trace['connections'][1]['closedSeconds']=.1
            elif kind=='time':trace['connections'][1]['acceptedSeconds']=float('nan')
            elif kind=='reason':trace['connections'][1]['closeReason']='peerReset'
            elif kind=='secret':trace['connections'][0]['url']='secret'
            elif kind=='bool':trace['acceptedCount']=True
            elif kind=='duplicate':rows+=copy.deepcopy(rows)
            else:rows=[]
            with self.subTest(kind=kind),self.assertRaises(ValueError):summarize_lifecycle(trace,rows)
    def test_rejects_globally_missing_request_and_impossible_connection_limit(self):
        trace,rows=evidence();trace['connections'][1]['requestIds']=[2];rows[0]['requestId']=2
        with self.assertRaises(ValueError):summarize_lifecycle(trace,rows)
        trace,rows=evidence();trace.update(rejectedCount=1,rejections=[dict(elapsed=.6,reason='connectionLimit',active=0)])
        with self.assertRaises(ValueError):summarize_lifecycle(trace,rows)

    def test_request_record_limit_is_not_mistaken_for_unparsed_peer_close(self):
        trace,rows=evidence()
        trace['connections'][0]['requestIds']=list(range(1,10001))
        trace['connections'][1].update(requestIds=[],unrecordedRequests=1,closeReason='requestRecordLimit')
        rows=[dict(connectionId=1,requestId=i,connectionRequestIndex=i) for i in range(1,10001)]
        result=summarize_lifecycle(trace,rows)
        self.assertFalse(result['complete']);self.assertEqual(result['unrecordedRequests'],1)
        self.assertEqual(result['withoutParsedRequest'],[])

    def test_unfinished_or_truncated_evidence_stays_incomplete(self):
        trace,rows=evidence();trace['connections'][0].update(closedSeconds=None,closeReason=None)
        self.assertFalse(summarize_lifecycle(trace,rows)['complete'])
        trace,rows=evidence();trace.update(rejectedCount=33,droppedRejections=1,rejections=[dict(elapsed=.1,reason='activeLimit',active=8) for _ in range(32)])
        result=summarize_lifecycle(trace,rows);self.assertFalse(result['complete']);self.assertEqual(result['rejectedCount'],33)
