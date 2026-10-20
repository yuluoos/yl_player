import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from test_live_summary import baseline_evidence
from test_aggregate_experiment import conditions
try:
    from aggregate_live import make_plan, summarize_experiment
except ImportError:
    make_plan = summarize_experiment = None


class AggregateLiveTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(make_plan, 'Repeated live measurement aggregation is missing')
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_all_protocols_and_unrun_attempts_remain_in_denominator(self):
        plan = make_plan('live', conditions(), 2, ['cold', 'warm'])
        report = summarize_experiment(plan, self.root)
        self.assertEqual(report['planned'], 24)
        self.assertEqual(report['statusCounts']['not_run'], 24)
        self.assertFalse(report['matrixComplete'])
        self.assertEqual(len(report['cohorts']), 12)

    def test_raw_log_join_failure_retention_and_percentiles(self):
        plan = make_plan('live', conditions(), 1, ['cold'])
        for trial in plan['trials']:
            r, s, receipt, connections = baseline_evidence(trial['baselineMode'])
            for row in s: row['managedBufferedUs'] = 100
            for row in [r, receipt, *connections]:
                row.update(runId=trial['runId'], protocol=trial['protocol'],
                           profileId=conditions()['profileId'], profileHash=conditions()['profileHash'],
                           declaredMediaHash=conditions()['mediaHash'])
            for row in s: row['runId'] = trial['runId']
            r.update(platform='macos', buildMode='debug')
            contents = dict(capture=''.join('YL_LIVE_SAMPLE='+json.dumps(v)+'\n' for v in s)+
                'YL_LIVE_RESULT='+json.dumps(r)+'\n', receipt=json.dumps(receipt),
                connections=''.join(json.dumps(v)+'\n' for v in connections))
            refs = {}
            for name, content in contents.items():
                path = self.root / (trial['runId']+'-'+name)
                path.write_text(content)
                refs[name] = dict(path=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            trial.update(artifacts=refs, exitCode=0)
        report = summarize_experiment(plan, self.root)
        self.assertTrue(report['matrixComplete'])
        self.assertEqual(report['cohorts'][0]['metrics']['maximumManagedBufferedUs']['p95'], 100)
        self.assertFalse(report['capabilityAccepted'])
        plan['trials'][0]['exitCode'] = 1
        (self.root / plan['trials'][1]['artifacts']['receipt']['path']).write_text('tampered')
        report = summarize_experiment(plan, self.root)
        self.assertEqual(report['statusCounts']['failed'], 1)
        self.assertEqual(report['statusCounts']['invalid_artifacts'], 1)
        self.assertEqual(report['eligible'], 4)
        self.assertEqual(report['planned'], 6)

    def test_array_null_scalar_results_are_invalid_trials_not_experiment_crashes(self):
        for invalid in ([], None, 1, 'bad'):
            plan = make_plan('live', conditions(), 1, ['cold'])
            trial = plan['trials'][0]
            refs = {}
            for name, content in dict(capture='YL_LIVE_RESULT='+json.dumps(invalid),
                                      receipt='{}', connections='').items():
                path = self.root / name
                path.write_text(content)
                refs[name] = dict(path=name, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            trial.update(artifacts=refs, exitCode=0)
            report = summarize_experiment(plan, self.root)
            self.assertEqual(report['statusCounts']['invalid_artifacts'], 1)
            self.assertEqual(report['planned'], 6)

    def test_duplicate_missing_and_traversal_trials_rejected(self):
        for mutation in ('missing', 'duplicate', 'path'):
            plan = make_plan('live', conditions(), 1, ['cold'])
            if mutation == 'missing': plan['trials'].pop()
            if mutation == 'duplicate': plan['trials'][1] = plan['trials'][0].copy()
            if mutation == 'path':
                plan['trials'][0]['artifacts'] = {k: dict(path='../secret', sha256='a'*64)
                    for k in ('capture', 'receipt', 'connections')}
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                summarize_experiment(plan, self.root)

if __name__ == '__main__': unittest.main()
