"""Evidence must prove real output, not merely enqueue activity."""
import copy
import unittest
from collect_timed_video import evaluate


def observation():
    def row(phase, total, drops=0):
        return dict(phase=phase, uptime=1.0, candidateActuallyUsed=True, submitted=total,
                    applicationDrops=drops, rejected=0, workerMaxGapSeconds=.01,
                    systemMetrics=dict(total=total, dropped=0, corrupted=0, accumulatedDelay=.01*total),
                    failures=[], ledgerBytes=0, pending=False)
    return dict(rows=[row('playing', 30), row('activeEnd', 60), row('disposed', 60), row('disposedLater', 60)],
                pausedPixelPresent=True, stallSeconds=.251, submittedDuringStall=7)


class EvidenceTests(unittest.TestCase):
    def test_valid_real_output(self):
        self.assertEqual(evaluate(observation())['failures'], [])

    def test_reject_missing_or_fake_metrics(self):
        for patch in [dict(candidateActuallyUsed=False), dict(systemMetrics=None),
                      dict(systemMetrics=dict(total=0, dropped=0, corrupted=0, accumulatedDelay=0))]:
            value = observation(); value['rows'][1].update(patch)
            with self.subTest(patch=patch): self.assertTrue(evaluate(value)['failures'])

    def test_regression_drop_cleanup_and_gap(self):
        for patch in [dict(applicationDrops=1), dict(rejected=1), dict(workerMaxGapSeconds=.101),
                      dict(failures=['render.failed'])]:
            value=observation(); value['rows'][1].update(patch)
            with self.subTest(patch=patch): self.assertTrue(evaluate(value)['failures'])
        for field, number in [('total', 29), ('dropped', 1), ('corrupted', 1), ('accumulatedDelay', -1)]:
            value=observation(); value['rows'][1]['systemMetrics'][field]=number
            with self.subTest(field=field): self.assertTrue(evaluate(value)['failures'])
        for patch in [dict(ledgerBytes=1), dict(pending=True)]:
            value=observation(); value['rows'][-1].update(patch)
            self.assertTrue(evaluate(value)['failures'])

    def test_missing_disposal_stall_and_pixel(self):
        for key, value in [('pausedPixelPresent',False), ('stallSeconds',.2), ('submittedDuringStall',0)]:
            sample=observation(); sample[key]=value
            self.assertTrue(evaluate(sample)['failures'])
        sample=observation(); sample['rows'].pop(); self.assertTrue(evaluate(sample)['failures'])

    def test_nonfinite_is_not_evidence(self):
        for number in [float('nan'),float('inf'), True, None, -1]:
            sample=observation(); sample['rows'][1]['workerMaxGapSeconds']=number
            self.assertTrue(evaluate(sample)['failures'])

if __name__ == '__main__': unittest.main()
