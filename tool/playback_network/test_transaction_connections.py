import copy
import unittest
import test_proxy_boundaries as boundary_fixture
from test_transaction_metrics import metrics
from test_connection_lifecycle import evidence
from proxy_boundaries import record_proxy_observation
from connection_lifecycle import summarize_lifecycle
try:
    import transaction_connections as connections
except ImportError:
    connections = None

TOKEN = 'a'*64
CORRELATION = '87654321-1234-1234-1234-123456789abc'


class TransactionConnectionTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(connections, 'transaction connection analyzer missing')
        base = boundary_fixture.ProxyBoundaryTests(); base.setUp()
        self.boundaries = [dict(base.trace,version=2,metrics=metrics(),correlationID=CORRELATION)]
        self.server = [dict(base.server,requestId=1,connectionId=2,connectionRequestIndex=1,proxyTraceID=CORRELATION)]
        self.boundaries[0]['serverRequestID'] = 1
        self.trace, _ = evidence(); self.trace['version'] = 2
        for index, row in enumerate(self.trace['connections']):row['connectionToken'] = TOKEN if index==1 else 'b'*64
        self.sidecar = [dict(version=1,proxyID=base.trace['proxyID'],requestID=1,correlationID=CORRELATION,
            transactions=[dict(index=0,connectionToken=TOKEN,proxyConnection=False,responsePresent=True)])]

    def summarize(self):
        receipt = {'errors':[]}
        record_proxy_observation(receipt,self.boundaries,self.server,2)
        summary = summarize_lifecycle(self.trace,self.server)
        return connections.summarize_connections(self.sidecar,self.boundaries,receipt.get('proxyRequestObservation'),self.trace,summary)

    def test_known_hmac_vector(self):
        self.assertEqual(connections.connection_token(b'0123456789abcdef'*4,('127.0.0.1',54321),('127.0.0.1',8080)),
            'b93437e984e46bdf0227cb06708354812141a850a8190a619cc23d4cfe6dbb8e')

    def test_v3_preserves_exact_foundation_task_identity_without_inventing_legacy_identity(self):
        self.sidecar[0].update(version=3,foundationTaskID='<87654321-1234-1234-1234-123456789abc>.<1>')
        self.sidecar[0]['transactions'][0]['endpointFields']=15
        result=self.summarize()
        self.assertEqual(result['requests'][0]['foundationTaskID'],self.sidecar[0]['foundationTaskID'])
        self.sidecar[0]['foundationTaskID']=None
        self.assertIsNone(self.summarize()['requests'][0]['foundationTaskID'])
        for value in ('', 'http://private?token=secret', '<87654321-1234-1234-1234-123456789abc>.<1> secret', 1):
            self.sidecar[0]['foundationTaskID']=value
            with self.subTest(value=value),self.assertRaises(ValueError):self.summarize()
        self.sidecar[0].pop('foundationTaskID');self.sidecar[0]['version']=2
        self.assertNotIn('foundationTaskID',self.summarize()['requests'][0])

    def test_binds_only_unique_token_and_keeps_ambiguous_proxy_and_unknown_unbound(self):
        result=self.summarize(); transaction=result['requests'][0]['transactions'][0]
        self.assertEqual(transaction['connectionId'],2);self.assertEqual(transaction['binding'],'bound');self.assertTrue(result['complete'])
        for mode in ('ambiguous','proxy','missing-token','unmatched'):
            with self.subTest(mode=mode):
                trace=copy.deepcopy(self.trace);sidecar=copy.deepcopy(self.sidecar)
                if mode=='ambiguous':self.trace['connections'][0]['connectionToken']=TOKEN
                elif mode=='proxy':self.sidecar[0]['transactions'][0]['proxyConnection']=True
                elif mode=='missing-token':self.sidecar[0]['transactions'][0]['connectionToken']=None
                else:self.sidecar[0]['transactions'][0]['connectionToken']='c'*64
                result=self.summarize();self.assertIsNone(result['requests'][0]['transactions'][0]['connectionId']);self.assertFalse(result['complete'])
                self.trace=trace;self.sidecar=sidecar

    def test_missing_callback_is_unknown_and_zero_transactions_is_explicit(self):
        self.sidecar=[]
        result=self.summarize();self.assertEqual(result['requests'][0]['availability'],'unknown');self.assertFalse(result['complete'])
        self.boundaries[0]['metrics'].update(transactionCount=0,transactions=[])
        self.sidecar=[dict(version=1,proxyID=self.boundaries[0]['proxyID'],requestID=1,correlationID=CORRELATION,transactions=[])]
        result=self.summarize();self.assertEqual(result['requests'][0]['availability'],'no-transactions')
        self.assertEqual(result['requests'][0]['transactions'],[])

    def test_rejects_orphans_duplicates_wrong_identity_count_index_and_raw_endpoints(self):
        for kind in ('orphan','duplicate','correlation','count','index','secret','bool','token','callback-without-metrics'):
            saved=copy.deepcopy(self.sidecar);boundary=copy.deepcopy(self.boundaries)
            if kind=='orphan':self.sidecar[0]['requestID']=2
            elif kind=='duplicate':self.sidecar*=2
            elif kind=='correlation':self.sidecar[0]['correlationID']=self.sidecar[0]['proxyID']
            elif kind=='count':self.sidecar[0]['transactions']=[]
            elif kind=='index':self.sidecar[0]['transactions'][0]['index']=1
            elif kind=='secret':self.sidecar[0]['transactions'][0]['remoteAddress']='127.0.0.1'
            elif kind=='bool':self.sidecar[0]['transactions'][0]['responsePresent']=1
            elif kind=='token':self.sidecar[0]['transactions'][0]['connectionToken']='bad'
            else:self.boundaries[0]['metrics']=None
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.summarize()
            self.sidecar=saved;self.boundaries=boundary

    def test_invalid_main_evidence_is_not_used_and_strict_failure_is_preserved(self):
        self.boundaries[0]['terminal']=0
        with self.assertRaises(ValueError):self.summarize()
        self.boundaries[0]['terminal']=10.33;self.boundaries[0]['metrics']=None
        receipt={'errors':['strict failure']}
        connections.record_connections(receipt,[],self.boundaries,None,self.trace,summarize_lifecycle(self.trace,self.server))
        self.assertIn('strict failure',receipt['errors']);self.assertFalse(receipt['transactionConnectionObservation']['complete'])
        self.assertEqual(receipt['transactionConnectionObservation']['availability'],'unknown')

    def test_truncated_metrics_bind_only_the_first_32_transactions(self):
        metrics=self.boundaries[0]['metrics'];metrics.update(transactionCount=33,truncated=1)
        metrics['transactions']*=32
        self.sidecar[0]['transactions']=[dict(self.sidecar[0]['transactions'][0],index=index) for index in range(32)]
        result=self.summarize();self.assertFalse(result['complete'])
        self.assertEqual(len(result['requests'][0]['transactions']),32)
        self.sidecar[0]['transactions'].append(dict(self.sidecar[0]['transactions'][0],index=32))
        with self.assertRaises(ValueError):self.summarize()

    def test_v2_lifecycle_rejects_invalid_tokens_and_v1_rejects_token_fields(self):
        for token in (None,1,'BAD','A'*64):
            self.trace['connections'][0]['connectionToken']=token
            with self.subTest(token=token),self.assertRaises(ValueError):summarize_lifecycle(self.trace,self.server)
        self.trace['version']=1
        with self.assertRaises(ValueError):summarize_lifecycle(self.trace,self.server)

    def test_saved_capture_cli_keeps_failed_strict_metrics_and_unknown_callback(self):
        import contextlib
        import io
        import json
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        self.boundaries[0]['metrics']=None
        with tempfile.TemporaryDirectory() as tmp:
            directory=Path(tmp)
            for name,rows in [('proxy-requests',self.boundaries),('requests',self.server),('rows',[{'proxyRequestSamplingVersion':2}])]:
                (directory/(name+'.jsonl')).write_text(''.join(json.dumps(row)+'\n' for row in rows))
            (directory/'connection-lifecycle.json').write_text(json.dumps(self.trace))
            output=io.StringIO()
            with patch('sys.argv',['transaction_connections.py',tmp]),contextlib.redirect_stdout(output):
                self.assertEqual(connections.main(),1)
            result=json.loads(output.getvalue())
            self.assertIn('proxy successful transaction metrics incomplete',result['errors'])
            self.assertEqual(result['transactionConnectionObservation']['requests'][0]['availability'],'unknown')

    def test_missing_main_correlation_cannot_be_bound_by_empty_sidecar_identity(self):
        self.boundaries[0].pop('correlationID')
        self.sidecar[0]['correlationID']=''
        with self.assertRaises(ValueError):self.summarize()

    def test_v2_endpoint_fields_distinguish_absent_from_unsupported_endpoints(self):
        self.sidecar[0]['version']=2
        item=self.sidecar[0]['transactions'][0]
        item['connectionToken']=None
        for mask,binding in [(0,'endpoint-unavailable'),(7,'endpoint-unavailable'),(15,'unsupported-endpoint')]:
            item['endpointFields']=mask
            with self.subTest(mask=mask):
                result=self.summarize();transaction=result['requests'][0]['transactions'][0]
                self.assertEqual(transaction['endpointFields'],mask)
                self.assertEqual(transaction['binding'],binding)
                self.assertIsNone(transaction['connectionId']);self.assertFalse(result['complete'])
        item.update(connectionToken=TOKEN,endpointFields=15)
        result=self.summarize();self.assertTrue(result['complete'])
        self.assertEqual(result['requests'][0]['transactions'][0]['connectionId'],2)

    def test_v2_endpoint_fields_reject_invalid_missing_or_inconsistent_masks(self):
        self.sidecar[0]['version']=2
        item=self.sidecar[0]['transactions'][0]
        item['connectionToken']=None
        for mask in (-1,16,True,False,1.0,None,'15'):
            item['endpointFields']=mask
            with self.subTest(mask=mask),self.assertRaises(ValueError):self.summarize()
        item.pop('endpointFields')
        with self.assertRaises(ValueError):self.summarize()
        item['connectionToken']=TOKEN
        for mask in range(15):
            item['endpointFields']=mask
            with self.subTest(incompleteMask=mask),self.assertRaises(ValueError):self.summarize()

    def test_v1_nil_token_keeps_legacy_unknown_fields_without_inferred_mask(self):
        self.sidecar[0]['transactions'][0]['connectionToken']=None
        result=self.summarize();transaction=result['requests'][0]['transactions'][0]
        self.assertEqual(transaction['binding'],'endpoint-unavailable')
        self.assertNotIn('endpointFields',transaction)
        self.assertIsNone(transaction['connectionId']);self.assertFalse(result['complete'])
