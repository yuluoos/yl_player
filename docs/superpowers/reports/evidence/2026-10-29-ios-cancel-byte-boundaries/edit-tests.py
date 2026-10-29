from pathlib import Path
p=Path('tool/playback_network/test_transaction_metrics.py')
s=p.read_text();s+='''

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
''';p.write_text(s)
