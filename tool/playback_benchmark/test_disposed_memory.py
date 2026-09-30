import unittest
from resources import summarize_disposed_memory
from test_resources import sample, trial


def cycle(attempt, rss, footprint, *, outcome='passed', power='ac', thermal='nominal'):
    a = sample(attempt * 10000000, attempt * 100, 'disposed')
    b = sample(attempt * 10000000 + 2000000, attempt * 100 + 1, 'disposed')
    for row in (a, b):
        row.update(rssBytes=rss, footprintBytes=footprint, power=power, thermal=thermal)
    result = trial([a, b], outcome)
    result.update(attempt=attempt, plannedAttempts=3, buildMode='profile')
    return result


class DisposedMemoryTests(unittest.TestCase):
    def test_compares_actual_endpoints_without_calling_growth_a_leak(self):
        r = summarize_disposed_memory([cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)])
        self.assertEqual([x['rssBytes'] for x in r['endpoints']], [100, 120, 110])
        self.assertEqual(r['deltaBytes'], {'rss': 10, 'footprint': 10})
        self.assertEqual(r['elapsedUs'], 20000000)
        self.assertIsNone(r['leakVerdict'])
        self.assertFalse(r['performanceBaseline'])

    def test_missing_final_reading_never_falls_back_to_earlier_value(self):
        rows = [cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)]
        rows[-1]['samples'][-1].update(status='unavailable', rssBytes=None, footprintBytes=None, cpuUs=None)
        r = summarize_disposed_memory(rows)
        self.assertIsNone(r['endpoints'][-1]['rssBytes'])
        self.assertIsNone(r['deltaBytes'])
        self.assertEqual(len(r['endpoints']), 3)

    def test_failure_skip_or_missing_disposed_window_cannot_compare(self):
        for change in ('failed', 'skipped', 'no-disposed', 'singleton'):
            rows = [cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)]
            if change in ('failed', 'skipped'):
                rows[1]['outcome'] = change
                if change == 'skipped': rows[1]['samples'] = []
            elif change == 'singleton': rows[1]['samples'] = rows[1]['samples'][-1:]
            else:
                for s in rows[1]['samples']: s['phase'] = 'playing'
            with self.subTest(change=change):
                r = summarize_disposed_memory(rows)
                self.assertIsNone(r['deltaBytes'])
                self.assertEqual(len(r['endpoints']), 3)

    def test_thermal_power_changes_or_unknown_conditions_remain_unqualified(self):
        for field, value in [('power', 'battery'), ('power', 'unknown'), ('thermal', 'serious'), ('thermal', 'unknown')]:
            rows = [cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)]
            rows[1]['samples'][0][field] = value
            with self.subTest(field=field, value=value):
                self.assertIsNone(summarize_disposed_memory(rows)['deltaBytes'])

    def test_cross_trial_clock_overlap_is_rejected(self):
        rows = [cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)]
        rows[1]['samples'][0]['monotonicUs'] = rows[0]['samples'][-1]['monotonicUs']
        with self.assertRaises(ValueError): summarize_disposed_memory(rows)

    def test_input_order_is_not_a_substitute_for_attempt_identity(self):
        rows = [cycle(1, 100, 80), cycle(2, 120, 85), cycle(3, 110, 90)]
        self.assertEqual(summarize_disposed_memory(list(reversed(rows)))['deltaBytes'],
                         {'rss': 10, 'footprint': 10})
        with self.assertRaises(ValueError): summarize_disposed_memory(rows[:2])


if __name__ == '__main__': unittest.main()
