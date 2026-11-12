import json
from pathlib import Path
import tempfile
import unittest
from run_ios_simulator_integration import service_uri, validate_results


class SimulatorBootstrapTests(unittest.TestCase):
    def test_only_current_process_can_supply_authenticated_endpoint(self):
        records = [{'processID': 11, 'eventMessage': 'flutter: The Dart VM service is listening on http://127.0.0.1:1234/old=/'},
                   {'processID': 12, 'eventMessage': 'flutter: The Dart VM service is listening on http://127.0.0.1:4567/new=/'}]
        self.assertEqual(service_uri(records, 12), 'http://127.0.0.1:4567/new=/')
        self.assertIsNone(service_uri(records, 13))

    def test_remote_or_unauthenticated_endpoints_are_rejected(self):
        for uri in ['http://example.test:1234/token/', 'http://127.0.0.1:1234/', 'http://user:pass@localhost:1234/token/']:
            with self.assertRaises(ValueError):
                service_uri([{'processID': 12, 'eventMessage': 'The Dart VM service is listening on ' + uri}], 12)

    def test_empty_and_failed_receipts_never_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            for data in [{}, {'ciCases': {}}, {'ciCases': {'actual case': 'failure'}}]:
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    validate_results(path)
            path.write_text(json.dumps({'ciCases': {'actual case': 'success'}}))
            validate_results(path)


if __name__ == '__main__':
    unittest.main()
