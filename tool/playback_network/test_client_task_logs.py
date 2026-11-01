import json
from pathlib import Path
import tempfile
import unittest

from abr_accesslog import record_client_tasks


TASK = '<87654321-1234-1234-1234-123456789abc>.<46>'


class ClientTaskTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.out = Path(temp.name)
        (self.out/'process.json').write_text(json.dumps(dict(pid=73, token='capture')))
        self.requests = [dict(proxyID='proxy', requestID=46, foundationTaskID=TASK),
                         dict(proxyID='proxy', requestID=47)]

    def record(self, messages):
        with (self.out/'client-network.jsonl').open('w') as log:
            for pid, subsystem, message in messages:
                print(json.dumps(dict(pid=pid, subsystem=subsystem, message=message)), file=log)
        receipt = dict(errors=[], transactionConnectionObservation=dict(requests=self.requests))
        record_client_tasks(self.out, receipt, 'capture')
        return receipt

    def test_waiting_and_setting_up_are_distinct_from_using_a_connection(self):
        cf = 'com.apple.CFNetwork'
        task = 'Task ' + TASK.upper()
        receipt = self.record([(73, cf, task+' not allowed to create new connection (existingConnection 11)'),
                               (73, cf, task+' setting up Connection 12'),
                               (73, 'com.apple.network', 'tcp_output [C12:2] flags=[S]'),
                               (73, cf, 'unrelated '+task+' now using Connection 999'),
                               (73, cf, task+' setting up Connection 13'),
                               (73, cf, task+' now using Connection 13')])
        obs = receipt['clientTaskObservation']
        self.assertEqual(obs['matchedTaskCount'], 1)
        self.assertFalse(obs['complete'])
        self.assertIn('client task evidence incomplete', receipt['errors'])
        first, unknown = obs['requests']
        self.assertEqual(first['taskLogIndices'], [0, 1, 4, 5])
        self.assertEqual(first['setupConnectionIDs'], [12, 13])
        self.assertEqual(first['usedConnectionIDs'], [13])
        self.assertEqual(obs['connectionLogIndices']['12'], [2])
        self.assertEqual(unknown['taskLogIndices'], [])
        self.assertNotIn('unrelated', json.dumps(obs))

    def test_foreign_pid_invalidates_the_requested_observation(self):
        receipt = self.record([(74, 'com.apple.CFNetwork', 'Task '+TASK+' now using Connection 12')])
        self.assertFalse(receipt['clientTaskObservation']['complete'])
        self.assertEqual(receipt['clientTaskObservation']['requests'], [])
        self.assertIn('client task evidence unavailable or invalid', receipt['errors'])

    def test_all_identities_can_match_without_a_connection_being_established(self):
        self.requests.pop()
        receipt = self.record([(73, 'com.apple.CFNetwork', 'Task '+TASK+' setting up Connection 12')])
        obs = receipt['clientTaskObservation']
        self.assertTrue(obs['complete'])
        self.assertEqual(receipt['errors'], [])
        self.assertEqual(obs['requests'][0]['usedConnectionIDs'], [])
