import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name('summarize.py')


def record(**updates):
    row = dict(schemaVersion=1, runId='run-1', caseId='local-avc',
               commit='a' * 40, sourceHash='b' * 64, dependencyHash='c' * 64,
               artifactHash='d' * 64, mediaHash='e' * 64,
               platform='macos', device='MacBookPro17-1', os='macOS-27.0',
               architecture='arm64', deviceKind='physical', buildMode='debug',
               power='ac', thermal='unknown', output='internal',
               networkProfile='local-file', cacheState='os-cache-uncontrolled',
               measurement='load-to-public-first-frame-event', purpose='smoke',
               baselineComparable=True, plannedAttempts=1, attempt=1,
               outcome='passed', startedUs=500, firstPresentedUs=600,
               firstFrameUs=100)
    row.update(updates)
    return row


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(TOOL.exists(), 'benchmark summarizer is not implemented')
        spec = importlib.util.spec_from_file_location('summary_under_test', TOOL)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_failures_retained_and_p95_nearest_rank(self):
        rows = [dict(outcome='passed', firstFrameUs=100),
                dict(outcome='timeout', firstFrameUs=None),
                dict(outcome='passed', firstFrameUs=300)]
        result = self.module.summarize(rows)
        self.assertEqual(result['attempts'], 3)
        self.assertEqual(result['passed'], 2)
        self.assertEqual(result['timeouts'], 1)
        self.assertEqual(result['firstFrameUs'], dict(n=2, p50=200, p95=300, maximum=300))
        self.assertEqual(result['nonPassRate'], 1 / 3)

    def test_no_success_means_no_latency_statistics(self):
        result = self.module.summarize([
            dict(outcome='failed', firstFrameUs=200),
            dict(outcome='skipped', firstFrameUs=None),
            dict(outcome='cancelled', firstFrameUs=None)])
        self.assertIsNone(result['firstFrameUs'])
        self.assertEqual(result['failed'], 1)
        self.assertEqual(result['skipped'], 1)
        self.assertEqual(result['cancelled'], 1)
        self.assertEqual(result['nonPassRate'], 1)

    def test_p95_not_maximum_for_twenty_observations(self):
        result = self.module.summarize([dict(outcome='passed', firstFrameUs=i)
                                        for i in range(1, 21)])
        self.assertEqual(result['firstFrameUs']['p95'], 19)
        self.assertEqual(result['firstFrameUs']['p50'], 10.5)

    def test_rejects_invalid_statistics_not_silently_discarded(self):
        for rows in [[], [dict(outcome='passed', firstFrameUs=None)],
                     [dict(outcome='passed', firstFrameUs=-1)],
                     [dict(outcome='passed', firstFrameUs=True)],
                     [dict(outcome='passed', firstFrameUs=float('nan'))],
                     [dict(outcome='unknown', firstFrameUs=100)]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.module.summarize(rows)

    def test_complete_records_and_failure_denominator(self):
        rows = [record(plannedAttempts=2),
                record(plannedAttempts=2, attempt=2, outcome='timeout',
                       firstPresentedUs=None, firstFrameUs=None)]
        result = self.module.summarize_records(rows)
        self.assertEqual(result['summary']['attempts'], 2)
        self.assertEqual(result['summary']['nonPassRate'], 0.5)
        self.assertEqual(result['conditions']['sourceHash'], 'b' * 64)
        self.assertEqual(result['conditions']['measurement'], 'load-to-public-first-frame-event')

    def test_rejects_missing_identity_mixed_conditions_and_extra_secret_fields(self):
        for field in ['sourceHash', 'device', 'mediaHash', 'artifactHash']:
            row = record()
            del row[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.module.summarize_records([row])
        for field, value in [('cacheState', 'warm'), ('buildMode', 'release'),
                             ('device', 'other-device'), ('sourceHash', 'f' * 64),
                             ('mediaHash', 'f' * 64), ('thermal', 'nominal')]:
            rows = [record(plannedAttempts=2), record(plannedAttempts=2, attempt=2)]
            rows[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.module.summarize_records(rows)
        for field, value in [('url', 'https://secret.test/token=private'),
                             ('caseId', 'https://secret.test/'), ('commit', 'not-a-sha'),
                             ('attempt', True), ('firstPresentedUs', 700),
                             ('firstFrameUs', 101)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.module.summarize_records([record(**{field: value})])

    def test_rejects_duplicate_or_missing_trials(self):
        for rows in [[record(plannedAttempts=2)], [record(), record()],
                     [record(attempt=2)], [record(plannedAttempts=0)]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.module.summarize_records(rows)

    def test_baseline_requires_measured_conditions_and_profile_or_release(self):
        for changes in [dict(purpose='baseline'),
                        dict(purpose='baseline', buildMode='release')]:
            with self.assertRaises(ValueError):
                self.module.summarize_records([record(**changes)])
        result = self.module.summarize_records([record(purpose='baseline',
            buildMode='release', thermal='nominal', cacheState='warm')])
        self.assertEqual(result['conditions']['purpose'], 'baseline')

    def test_cli_rejects_invalid_input_without_echoing_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rows.jsonl'
            path.write_text(json.dumps(record(caseId='https://secret.test/secret')) + '\n')
            result = subprocess.run([sys.executable, str(TOOL), str(path)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('secret', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            path.write_text(json.dumps(record()) + '\n')
            result = subprocess.run([sys.executable, str(TOOL), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['summary']['passed'], 1)

    def test_json_duplicate_keys_and_nonfinite_values_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rows.jsonl'
            for payload in ['{"outcome":"failed","outcome":"passed"}', '{"x": NaN}']:
                path.write_text(payload + '\n')
                result = subprocess.run([sys.executable, str(TOOL), str(path)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
