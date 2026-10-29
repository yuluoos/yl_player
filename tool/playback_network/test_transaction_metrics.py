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
