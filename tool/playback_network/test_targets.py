import unittest
try:
    from evaluate_targets import freeze, compare
except ImportError:
    freeze = compare = None


def report():
    return dict(matrixComplete=True, conditions=dict(device='mac', os='os', platform='macos',
        architecture='arm64', deviceKind='physical', buildMode='profile',
        sourceSha256='a'*64, artifactSha256='b'*64, dependencySha256='c'*64,
        profileId='down-and-recover-v1', profileHash='d'*64, mediaHash='e'*64),
        cohorts=[dict(mode='auto', cacheState='cold', planned=3, eligible=3, excluded=0,
            metrics={'firstFrameUs': dict(observed=3, unavailable=0, p50=100, p95=200)})])


class TargetsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(freeze, 'Frozen target comparison is missing')

    def targets(self):
        return freeze(report(), 'f'*64, [dict(mode='auto', cacheState='cold',
            minimumSamples=3, maxima={'firstFrameUs': 250})])

    def test_freeze_requires_measured_complete_baseline_and_explicit_limits(self):
        baseline = report(); baseline['matrixComplete'] = False
        with self.assertRaises(ValueError):
            freeze(baseline, 'f'*64, [dict(mode='auto', cacheState='cold', minimumSamples=3,
                                        maxima={'firstFrameUs': 250})])
        self.assertEqual(self.targets()['baselineSha256'], 'f'*64)
        self.assertEqual(self.targets()['limits'][0]['maxima']['firstFrameUs'], 250)

    def test_new_build_identity_allowed_but_device_profile_and_media_must_match(self):
        candidate = report(); candidate['conditions']['sourceSha256'] = '0'*64
        self.assertEqual(compare(self.targets(), candidate)['status'], 'passed')
        candidate['conditions']['device'] = 'other'
        with self.assertRaises(ValueError): compare(self.targets(), candidate)

    def test_missing_metrics_failed_trials_and_insufficient_samples_never_pass(self):
        for mutation in ('unknown', 'excluded', 'small', 'threshold'):
            candidate = report(); cohort = candidate['cohorts'][0]
            if mutation == 'unknown': cohort['metrics']['firstFrameUs'].update(p95=None, unavailable=3, observed=0)
            if mutation == 'excluded':
                candidate['matrixComplete'] = False
                cohort.update(eligible=2, excluded=1)
            if mutation == 'small':
                cohort.update(planned=2, eligible=2)
                cohort['metrics']['firstFrameUs']['observed'] = 2
            if mutation == 'threshold': cohort['metrics']['firstFrameUs']['p95'] = 251
            with self.subTest(mutation=mutation):
                self.assertNotEqual(compare(self.targets(), candidate)['status'], 'passed')

    def test_cannot_omit_a_cohort_or_invent_a_metric_to_freeze(self):
        with self.assertRaises(ValueError): freeze(report(), 'f'*64, [])
        with self.assertRaises(ValueError):
            freeze(report(), 'f'*64, [dict(mode='auto', cacheState='cold', minimumSamples=3,
                                        maxima={'unknown': 1})])

if __name__ == '__main__': unittest.main()
