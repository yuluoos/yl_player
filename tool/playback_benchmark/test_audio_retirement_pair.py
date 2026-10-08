import copy
import unittest
from run_audio_retirement_pair import analyze


def fixture():
    start = 1_000_000
    events = []
    for i in range(200):
        for kind, offset in [('rendered', 0), ('reference', 100_000), ('candidate', 110_000)]:
            events.append(dict(kind=kind, ordinal=i, rawUs=start+200_000+i*20_000+offset))
    samples = [dict(startedUs=start+i*10_000, endedUs=start+i*10_000+100,
                    latency=.08, referenceLatency=.08, quantumSeconds=.02,
                    maximumFramesToRender=960, outputSampleRate=48000,
                    rate=1, bypass=True, referencePlaying=True, candidatePlaying=True,
                    referenceSampleTime=i*480, candidateSampleTime=i*480,
                    pending=5, failure=None) for i in range(801)]
    return dict(scenario='steady', startedUs=start, endedUs=start+8_010_000,
                pid=123, startHostTime=100, events=events, samples=samples,
                actions=[], peakPending=6, pendingBeforeStop=0, pendingAfterStop=0, failure=None)


class PairTests(unittest.TestCase):
    def test_complete_and_early_gate(self):
        value = fixture()
        self.assertTrue(analyze(value)['complete'])
        value['events'][2]['rawUs'] -= 20_000
        result = analyze(value)
        self.assertFalse(result['complete'])
        self.assertEqual(result['earlyOrdinals'], [0])

    def test_missing_duplicate_and_pending_are_not_pass(self):
        for mutation in [lambda d: d['events'].pop(),
                         lambda d: d['events'].append(copy.copy(d['events'][0])),
                         lambda d: d.update(pendingBeforeStop=1),
                         lambda d: d.update(failure='unknownLatency')]:
            value = fixture(); mutation(value)
            self.assertFalse(analyze(value)['complete'])

    def test_invalid_observations_and_transport_fail(self):
        for mutation in [lambda d: d['samples'][1].update(latency=0),
                         lambda d: d['samples'][1].update(candidateSampleTime=9000),
                         lambda d: d.update(scenario='transport'),
                         lambda d: d['samples'].clear()]:
            value = fixture(); mutation(value)
            self.assertFalse(analyze(value)['complete'])

    def test_playing_windows_require_usable_paired_clocks(self):
        value = fixture()
        for sample in value['samples']:
            sample.update(referenceSampleTime=None, candidateSampleTime=None)
        self.assertFalse(analyze(value)['complete'])

        # Null clocks during pause are expected and must remain admissible.
        value = fixture(); start = value['startedUs']; value['scenario'] = 'transport'
        value['actions'] = [dict(name=name, startedUs=start+due, endedUs=start+due+100)
                            for name, due in [('pause', 1_000_000), ('resume', 1_500_000),
                                              ('rate2', 2_000_000), ('rate1', 3_000_000)]]
        for sample in value['samples']:
            offset = sample['startedUs']-start
            if 1_000_000 <= offset < 1_500_000:
                sample.update(referencePlaying=False, candidatePlaying=False,
                              referenceSampleTime=None, candidateSampleTime=None)
            if 2_000_000 <= offset < 3_000_000:
                sample.update(rate=2, bypass=False)
        self.assertTrue(analyze(value)['complete'])
        for sample in value['samples']:
            if start+2_250_000 <= sample['startedUs'] < start+2_900_000:
                sample.update(referenceSampleTime=None, candidateSampleTime=None)
        self.assertFalse(analyze(value)['complete'])
