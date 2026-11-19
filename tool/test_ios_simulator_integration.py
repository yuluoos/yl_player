import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import Mock
from run_ios_simulator_integration import launch_test_app, service_uri, validate_results, terminate_after_test


class SimulatorBootstrapTests(unittest.TestCase):
    def test_cold_launch_without_complete_pid_retries_on_same_device(self):
        first = subprocess.TimeoutExpired('simctl launch', 60, output=b'test.bundle: 12', stderr=b'cold')
        launched = subprocess.CompletedProcess([], 0, 'test.bundle: 345\n', '')
        run = Mock(side_effect=[first, None, launched])
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'launch.log'
            self.assertEqual(launch_test_app(run, 'device-A', 'test.bundle', log), 345)
            self.assertIn('cold', log.read_text())
            self.assertIn('345', log.read_text())
        first_call, boot, retry = run.call_args_list
        self.assertEqual(first_call, retry)
        self.assertIn('--terminate-running-process', retry.args[0])
        self.assertEqual(boot.args[0], ['xcrun', 'simctl', 'bootstatus', 'device-A', '-b'])

    def test_timeout_after_pid_keeps_the_launched_test_process(self):
        run = Mock(side_effect=subprocess.TimeoutExpired('simctl launch', 60, output=b'test.bundle: 123\n'))
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(launch_test_app(run, 'device-A', 'test.bundle', Path(directory) / 'launch.log'), 123)
        self.assertEqual(run.call_count, 1)

    def test_second_launch_timeout_and_explicit_launch_failure_stay_failures(self):
        timeout = subprocess.TimeoutExpired('simctl launch', 60)
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'launch.log'
            run = Mock(side_effect=[timeout, None, timeout])
            with self.assertRaises(subprocess.TimeoutExpired):
                launch_test_app(run, 'device-A', 'test.bundle', log)
            self.assertEqual(run.call_count, 3)
            run = Mock(return_value=subprocess.CompletedProcess([], 1, '', 'launch denied'))
            with self.assertRaises(subprocess.CalledProcessError):
                launch_test_app(run, 'device-A', 'test.bundle', log)
            self.assertEqual(run.call_count, 1)
            self.assertIn('launch denied', log.read_text())

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

    def test_cleanup_timeout_preserves_original_driver_failure(self):
        run = Mock(side_effect=subprocess.TimeoutExpired('simctl terminate', 15))
        with self.assertRaises(SystemExit) as failure:
            try:
                raise SystemExit(7)
            finally:
                terminate_after_test(run, 'simulator', 'test.bundle')
        self.assertEqual(failure.exception.code, 7)
        run.assert_called_once_with(['xcrun', 'simctl', 'terminate', 'simulator', 'test.bundle'],
                                    timeout=15, capture=True, check=False)


if __name__ == '__main__':
    unittest.main()
