import unittest
from joint_observations import summarize, decode_records, check_limits

class JointObservationTests(unittest.TestCase):
    def test_frozen_gate_rejects_missing_runs_and_out_of_envelope_observations(self):
        limits = dict(fixtures=['owned'], runs=3, maxAbsoluteDeltaUs=100, maxOutputGapExcessMs=10)
        good = summarize([dict(fixture='owned', run=i, rows=[{'deltaUs': 2}]) for i in range(3)])
        check_limits(good, limits)
        with self.assertRaises(ValueError): check_limits({}, limits)
        good['owned']['deltaUs']['absoluteMaximum'] = 101
        with self.assertRaises(ValueError): check_limits(good, limits)

    def test_missing_audio_is_retained_not_reported_as_zero(self):
        result = summarize([dict(fixture='owned', run=0, rows=[{'deltaUs': None}, {'deltaUs': -12}, {'deltaUs': 3}])])
        self.assertEqual(result['owned']['missingAudioPairs'], 1)
        self.assertEqual(result['owned']['deltaUs'], {'minimum': -12, 'maximum': 3, 'absoluteMaximum': 12, 'absoluteP95': 12})

    def test_cross_period_output_gap_uses_native_host_clock_not_public_position(self):
        rows = [dict(epoch=1, videoPtsUs=0, observedHostUs=1000, deltaUs=0),
                dict(epoch=2, videoPtsUs=1000, observedHostUs=3000, deltaUs=0)]
        result = summarize([dict(fixture='owned', run=0, rows=rows)])['owned']
        self.assertEqual(result['transitionOutputGapExcessMs']['maximum'], 1)

    def test_absent_measurements_stay_null(self):
        result = summarize([dict(fixture='owned', run=0, rows=[])])['owned']
        self.assertIsNone(result['deltaUs'])
        self.assertIsNone(result['periodWaitMs'])
        self.assertIsNone(result['readyMs'])

    def test_duplicates_and_nonfinite_values_reject(self):
        row = dict(fixture='owned', run=0, rows=[])
        with self.assertRaises(ValueError): summarize([row, row])
        with self.assertRaises(ValueError): decode_records('{"fixture":"owned","run":0,"rows":[],"readyMs":NaN}')

    def test_android_headers_and_rows_stay_grouped_without_guessing(self):
        text = '\n'.join([
            'I P01_JOINT: {"fixture":"owned","run":0,"elapsedMs":12}',
            'I P01_JOINT_ROW: {"fixture":"owned","run":0,"deltaUs":5}',
        ])
        self.assertEqual(decode_records(text)[0]['rows'][0]['deltaUs'], 5)
        with self.assertRaises(ValueError): decode_records(text.splitlines()[1])

    def test_legacy_period_wait_label_needs_explicit_unit_correction(self):
        row = dict(fixture='owned', run=0, rows=[], periodWaits=[{'period': 1, 'waitUs': 371}])
        with self.assertRaises(ValueError): summarize([row])
        self.assertEqual(summarize([row], legacy_apple_wait_ms=True)['owned']['periodWaitMs']['maximum'], 371)

if __name__ == '__main__': unittest.main()
