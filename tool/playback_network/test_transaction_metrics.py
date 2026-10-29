import copy
import unittest
try:
    from transaction_metrics import summarize_transactions
except ImportError:
    summarize_transactions = None


def transaction():
    return dict(fetchSeconds=.2, fetchToRequestSeconds=.03, dnsSeconds=None,
        connectSeconds=.02, tlsSeconds=None, requestSeconds=.01,
        responseWaitSeconds=.04, responseSeconds=.12, reused=0,
        protocolCode=1, fetchType=1)


def metrics():
    return dict(taskSeconds=.21, transactionCount=1, redirectCount=0,
        truncated=0, transactions=[transaction()])


class TransactionMetricsTests(unittest.TestCase):
    def setUp(self): self.assertIsNotNone(summarize_transactions)

    def test_preserves_unavailable_dns_tls_and_network_partition(self):
        source=metrics();before=copy.deepcopy(source);out=summarize_transactions(source)
        self.assertTrue(out['complete']);self.assertTrue(out['available'])
        self.assertIsNone(out['transactions'][0]['dnsSeconds'])
        self.assertIsNone(out['transactions'][0]['tlsSeconds'])
        self.assertEqual(out['transactions'][0]['connectSeconds'],.02)
        self.assertEqual(source,before)

    def test_missing_and_partial_metrics_are_not_zero_or_complete(self):
        out=summarize_transactions(None)
        self.assertFalse(out['available']);self.assertFalse(out['complete'])
        self.assertIsNone(out['taskSeconds'])
        data=metrics();data['transactions'][0]['responseSeconds']=None
        self.assertFalse(summarize_transactions(data)['complete'])
        data=metrics();data['transactions'][0]['fetchType']=3
        self.assertFalse(summarize_transactions(data)['complete'])

    def test_rejects_corrupt_values_and_identity_leaks(self):
        invalid=[]
        for key,value in [('connectSeconds',-1),('responseSeconds',float('nan')),
                ('reused',True),('requestSeconds',.1),('url','https://secret')]:
            data=metrics();data['transactions'][0][key]=value;invalid.append(data)
        invalid += [dict(metrics(),taskSeconds=-1),dict(metrics(),redirectCount=True),
                    dict(metrics(),transactions=[]),dict(metrics(),transactionCount=2)]
        for data in invalid:
            with self.subTest(data=data),self.assertRaises(ValueError):summarize_transactions(data)

    def test_empty_and_bounded_truncation_are_explicit(self):
        empty=dict(metrics(),transactionCount=0,transactions=[])
        self.assertFalse(summarize_transactions(empty)['complete'])
        bounded=dict(metrics(),transactionCount=33,transactions=[transaction()]*32,truncated=1)
        self.assertFalse(summarize_transactions(bounded)['complete'])
        with self.assertRaises(ValueError):summarize_transactions(dict(bounded,truncated=0))
        with self.assertRaises(ValueError):summarize_transactions(dict(bounded,transactions=[transaction()]*33))

    def test_zero_duration_is_valid_when_observed(self):
        data=metrics();data['transactions'][0].update(connectSeconds=0,dnsSeconds=0)
        self.assertTrue(summarize_transactions(data)['complete'])
        self.assertEqual(summarize_transactions(data)['transactions'][0]['dnsSeconds'],0)

    def test_task_and_redirect_counts_bound_observed_transactions(self):
        for data in [dict(metrics(),taskSeconds=0),dict(metrics(),redirectCount=99)]:
            with self.subTest(data=data),self.assertRaises(ValueError):summarize_transactions(data)
        self.assertTrue(summarize_transactions(dict(metrics(),taskSeconds=.2))['complete'])
        self.assertFalse(summarize_transactions(dict(metrics(),taskSeconds=None))['complete'])


class DurationStateTests(unittest.TestCase):
    def source(self):
        value=metrics();value['version']=2
        value['transactions'][0]['durationStates']={k:(3 if v is None else 0) for k,v in value['transactions'][0].items() if k.endswith('Seconds')}
        return value

    def test_distinguishes_unavailable_dates_without_promoting_partial_transaction(self):
        value=self.source();self.assertTrue(summarize_transactions(value)['complete'])
        early=copy.deepcopy(value['transactions'][0])
        for field,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:
            early[field]=None;early['durationStates'][field]=state
        value.update(transactionCount=2,transactions=[early,value['transactions'][0]])
        out=summarize_transactions(value)
        self.assertFalse(out['complete']);self.assertEqual(out['transactions'][0]['durationStates']['responseSeconds'],3)
        self.assertIsNone(out['transactions'][0]['fetchSeconds'])

    def test_rejects_missing_or_contradictory_states_and_version_downgrade(self):
        for mutation in ['missing','false-valid','false-missing','bool','unknown','extra','version','legacy-extra']:
            value=self.source();item=value['transactions'][0]
            if mutation=='missing':del item['durationStates']['fetchSeconds']
            elif mutation=='false-valid':item['durationStates']['dnsSeconds']=0
            elif mutation=='false-missing':item['durationStates']['fetchSeconds']=2
            elif mutation=='bool':item['durationStates']['fetchSeconds']=False
            elif mutation=='unknown':item['durationStates']['fetchSeconds']=5
            elif mutation=='extra':item['durationStates']['url']=0
            elif mutation=='version':value['version']=3
            else:del value['version']
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):summarize_transactions(value)


class TransportByteTests(unittest.TestCase):
    def test_v3_preserves_zero_and_unknown_counts_without_completing_missing_dates(self):
        source=DurationStateTests().source();source['version']=3
        source['transactions'][0]['transportBytes']=dict(requestHeaders=128,requestBody=0,responseHeaders=0,responseBody=None)
        for k,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:
            source['transactions'][0][k]=None;source['transactions'][0]['durationStates'][k]=state
        before=copy.deepcopy(source)
        try:result=summarize_transactions(source)
        except ValueError:self.fail('v3 transport counts unavailable')
        self.assertEqual(result['transactions'][0]['transportBytes'],dict(requestHeaders=128,requestBody=0,responseHeaders=0,responseBody=None))
        self.assertFalse(result['complete']);self.assertEqual(source,before)
        for field,value in [('requestBody',-1),('responseBody',True),('requestHeaders',1.5),('responseHeaders',2**63)]:
            invalid=copy.deepcopy(source);invalid['transactions'][0]['transportBytes'][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(ValueError):summarize_transactions(invalid)
        for mutate in ['missing','extra','downgrade']:
            invalid=copy.deepcopy(source)
            if mutate=='missing':del invalid['transactions'][0]['transportBytes']['requestHeaders']
            elif mutate=='extra':invalid['transactions'][0]['transportBytes']['url']='secret'
            else:invalid['version']=2
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):summarize_transactions(invalid)


class ByteEvidenceTests(unittest.TestCase):
    def test_missing_empty_legacy_and_unknown_are_not_reported_zero(self):
        empty=dict(metrics(),version=3,transactionCount=0,transactions=[])
        for source,state in [(None,'unavailable'),(empty,'no-transactions'),(metrics(),'legacy')]:
            with self.subTest(state=state):
                result=summarize_transactions(source)
                self.assertIn('byteEvidence',result)
                self.assertEqual(result['byteEvidence']['availability'],state)
        source=DurationStateTests().source();source['version']=3
        source['transactions'][0]['transportBytes']=dict(requestHeaders=None,requestBody=0,responseHeaders=0,responseBody=None)
        result=summarize_transactions(source)
        self.assertIn('byteEvidence',result)
        self.assertEqual(result['byteEvidence']['transactions'],[
            dict(index=0,request='unknown',response='unknown')])

    def test_positive_and_zero_counts_never_complete_missing_response_dates(self):
        source=DurationStateTests().source();source['version']=3
        first=source['transactions'][0]
        first['transportBytes']=dict(requestHeaders=313,requestBody=None,responseHeaders=0,responseBody=0)
        for field,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:
            first[field]=None;first['durationStates'][field]=state
        second=copy.deepcopy(first);second['transportBytes']=dict(requestHeaders=0,requestBody=0,responseHeaders=None,responseBody=4)
        source.update(transactionCount=2,transactions=[first,second]);before=copy.deepcopy(source)
        result=summarize_transactions(source)
        self.assertIn('byteEvidence',result)
        self.assertEqual(result['byteEvidence']['transactions'],[
            dict(index=0,request='positive',response='zero'),
            dict(index=1,request='zero',response='positive')])
        self.assertFalse(result['complete']);self.assertEqual(source,before)
        self.assertFalse(result['byteEvidence']['serverReceiptProven'])
        self.assertFalse(result['byteEvidence']['physicalTransmissionProven'])

    def test_truncation_and_unknown_counts_remain_visible(self):
        source=DurationStateTests().source();source['version']=3
        source['transactions'][0]['transportBytes']=dict(requestHeaders=0,requestBody=0,responseHeaders=0,responseBody=0)
        source.update(transactionCount=33,truncated=1,transactions=source['transactions']*32)
        result=summarize_transactions(source)
        self.assertIn('byteEvidence',result)
        self.assertEqual(result['byteEvidence']['availability'],'truncated')
        self.assertEqual(len(result['byteEvidence']['transactions']),32)
        self.assertFalse(result['complete'])
