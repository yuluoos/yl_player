import copy
import unittest


def observation():
    return dict(pid=42, mode='rendered', scenario='steady', phase='observed',
        captureStartUs=1000000, startedUs=1000000, endedUs=9000100, alive=0,
        events=[dict(ordinal=n, rawUs=1100000+n*10000, callbackType=1) for n in range(200)],
        samples=[dict(startedUs=1000000+n*10000, endedUs=1000001+n*10000,
                      sampleTime=n*480, sampleRate=48000,
                      presentationLatency=0.02, outputLatency=0.01, rate=1,
                      playing=True, bypass=True) for n in range(801)], actions=[])


class AudioCallbackModeTests(unittest.TestCase):
    def test_duplicate_missing_or_wrong_callback_cannot_qualify(self):
        from run_audio_callback_modes import validate_observation
        good = observation()
        validate_observation(good, 42, 'rendered', 'steady')
        for variant in ['duplicate', 'missing', 'wrong_type', 'wrong_pid', 'short', 'sample_gap']:
            bad = copy.deepcopy(good)
            if variant == 'duplicate': bad['events'][-1]['ordinal'] = 0
            if variant == 'missing': bad['events'].pop()
            if variant == 'wrong_type': bad['events'][0]['callbackType'] = 2
            if variant == 'wrong_pid': bad['pid'] = 43
            if variant == 'short': bad['endedUs'] = 2000000
            if variant == 'sample_gap': del bad['samples'][5:70]
            with self.assertRaises(ValueError, msg=variant):
                validate_observation(bad, 42, 'rendered', 'steady')

    def test_transport_requires_actual_ordered_pause_resume_rate_actions(self):
        from run_audio_callback_modes import validate_observation
        row = observation()
        row['scenario'] = 'transport'
        with self.assertRaises(ValueError): validate_observation(row, 42, 'rendered', 'transport')
        row['actions'] = [dict(name=name, startedUs=t, endedUs=t+100)
            for name,t in [('pause',2000000),('resume',2500000),('rate2',3000000),('rate1',4000000)]]
        for sample in row['samples']:
            sample['playing'] = not 2000100 <= sample['startedUs'] < 2500000
            sample['rate'] = 2 if 3000100 <= sample['startedUs'] < 4000000 else 1
            sample['bypass'] = sample['rate'] == 1
        validate_observation(row, 42, 'rendered', 'transport')
        row['actions'][2]['startedUs'] = 2400000
        with self.assertRaises(ValueError): validate_observation(row, 42, 'rendered', 'transport')

    def test_callback_bracket_keeps_missing_and_transport_crossings(self):
        from run_audio_callback_modes import callback_brackets
        row = observation()
        row['events'] = [dict(ordinal=0, rawUs=999999, callbackType=1),
                         dict(ordinal=1, rawUs=1015000, callbackType=1)]
        result = callback_brackets(row)
        self.assertEqual(result[0]['status'], 'unbracketed')
        self.assertEqual(result[1]['sampleRange'], [480, 960])
        self.assertEqual(result[1]['endFrameOffsets'], [-1568, -1088])
        row['actions'] = [dict(name='pause', startedUs=1011000, endedUs=1012000)]
        self.assertEqual(callback_brackets(row)[1]['status'], 'transport_crossing')

    def test_protocol_freezes_six_arms_and_all_observer_slots(self):
        from run_audio_callback_modes import planned_arms
        arms = planned_arms()
        self.assertEqual([(a['mode'],a['scenario']) for a in arms], [
            (mode,scenario) for scenario in ('steady','transport')
            for mode in ('consumed','rendered','playedBack')])
        self.assertEqual(sum(len(a['probes']) for a in arms), 36)
        self.assertTrue(all(p['status']=='not_observed' for a in arms for p in a['probes']))


if __name__ == '__main__': unittest.main()
