from pathlib import Path
import tempfile
import unittest
import resources
from run_resources import collect
from test_resources import sample, trial


def cycles():
    rows = []
    for attempt in range(1, 101):
        start = (attempt - 1) * 6500000 + 1
        points = [sample(start + offset, attempt * 10000000 + offset, phase)
                  for phase, offset in [('idle', 0), ('idle', 2000000),
                      ('opening', 2000001), ('playing', 2100000),
                      ('disposing', 4400000), ('disposed', 4400001),
                      ('disposed', 6500000 - 1)]]
        row = trial(points)
        row.update(schemaVersion=2, workload='playback', buildMode='profile',
                   attempt=attempt, plannedAttempts=100)
        rows.append(row)
    return rows


class EnduranceTests(unittest.TestCase):
    def summarize(self, rows):
        self.assertTrue(hasattr(resources, 'summarize_endurance'),
                        'Missing fixed-protocol endurance qualification')
        return resources.summarize_endurance(rows)

    def test_complete_run_reports_duration_without_leak_or_budget_claim(self):
        result = self.summarize(cycles())
        self.assertTrue(result['protocolCompleted'])
        self.assertEqual(result['outcomes'], {'passed': 100})
        self.assertEqual(result['observedSpanUs'], 649999999)
        self.assertIsNone(result['leakVerdict'])
        self.assertFalse(result['performanceBaseline'])

    def test_incomplete_short_or_missing_phase_cannot_qualify(self):
        for mutate in (lambda r: r.pop(),
                       lambda r: r[30]['samples'].__delitem__(3),
                       lambda r: r[30].update(engine='unknown')):
            rows = cycles(); mutate(rows)
            with self.assertRaises(ValueError): self.summarize(rows)
        rows = cycles()
        for index, point in enumerate(p for row in rows for p in row['samples']):
            point['monotonicUs'] = point['monotonicUs'] // 2 + index
        self.assertFalse(self.summarize(rows)['protocolCompleted'])

    def test_failed_and_skipped_attempts_remain_in_denominator(self):
        rows = cycles()
        rows[10]['outcome'] = 'timeout'
        rows[10]['samples'] = rows[10]['samples'][:3]
        for row in rows[11:]: row.update(outcome='skipped', samples=[], engine='unknown', decoder='unknown')
        result = self.summarize(rows)
        self.assertFalse(result['protocolCompleted'])
        self.assertEqual(result['outcomes'], {'passed': 10, 'timeout': 1, 'skipped': 89})
        self.assertEqual(result['plannedAttempts'], 100)

    def test_mixed_or_overlapping_trials_rejected(self):
        for mutate in (lambda r: r[30].update(pid=999),
                       lambda r: r[30]['samples'][0].update(monotonicUs=1),
                       lambda r: r[30].update(buildMode='debug')):
            rows = cycles(); mutate(rows)
            with self.assertRaises(ValueError): self.summarize(rows)

    def test_endurance_rejects_other_workloads_before_side_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            for options in ({}, {'profile_cycles': True, 'harness_only': True},
                            {'profile_cycles': True, 'lifetime_probes': True}):
                output = Path(directory)/'must-not-exist'
                with self.assertRaises(ValueError):
                    collect(output, 'unused', endurance=True, **options)
                self.assertFalse(output.exists())


if __name__ == '__main__': unittest.main()
