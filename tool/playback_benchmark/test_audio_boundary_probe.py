import copy
import unittest
from run_audio_boundary_probe import validate_observation


def observation(scenario):
    target = 1 if scenario == 'single' else 3 if scenario == 'pausedEOF' else 200
    group = 1 if scenario == 'reference' else 8
    submits = [dict(ordinal=i, boundary=i % group == 0 or i == target, frames=1024, rawUs=10) for i in range(1,target+1)]
    return dict(phase='observed', scenario=scenario, pid=42, target=target, groupSize=group,
        submissions=submits, events=[dict(ordinal=s['ordinal'], boundary=s['boundary'], generation=1, rawUs=400+s['ordinal']) for s in submits],
        accepted=target,pending=0,pendingBytes=0,pendingDurationUs=0,drained=True,alivePCM=0,peakCount=min(24,target),
        samples=[dict(rawUs=100,pending=1,bytes=8192,durationUs=21333,drained=False,playing=scenario!='pausedEOF'),
                 dict(rawUs=800,pending=0,bytes=0,durationUs=0,drained=True,playing=True)],
        actions=[dict(name='EOF',rawUs=20,playing=scenario!='pausedEOF'),dict(name='play',rawUs=300)])


class BoundaryProbeTests(unittest.TestCase):
    def test_accepts_all_defined_arms(self):
        for scenario in ('single','pausedEOF','grouped','reference'):
            row=observation(scenario)
            self.assertEqual(validate_observation(row,scenario,42)['buffers'],row['target'])

    def test_rejects_missing_duplicate_or_wrong_tail(self):
        row=observation('grouped')
        for modify in (lambda r:r['events'].pop(), lambda r:r['events'].append(r['events'][0]),
                       lambda r:r['submissions'][0].update(boundary=True),
                       lambda r:r['submissions'][0].update(frames=0)):
            value=copy.deepcopy(row);modify(value)
            with self.assertRaises(ValueError): validate_observation(value,'grouped',42)

    def test_rejects_unbounded_or_early_drain(self):
        for modify in (lambda r:r['samples'][0].update(pending=25),
                       lambda r:r['samples'][0].update(bytes=196609),
                       lambda r:r['samples'][0].update(durationUs=511993),
                       lambda r:r['samples'][0].update(drained=True),
                       lambda r:r.update(alivePCM=1)):
            row=observation('grouped');modify(row)
            with self.assertRaises(ValueError): validate_observation(row,'grouped',42)

    def test_requires_EOF_and_actual_drained_sample(self):
        for modify in (lambda r:r.update(actions=[]), lambda r:r['samples'].pop()):
            row=observation('single');modify(row)
            with self.assertRaises(ValueError): validate_observation(row,'single',42)

    def test_paused_EOF_cannot_be_faked(self):
        for modify in (lambda r:r['actions'][0].update(playing=True),
                       lambda r:r['events'][0].update(rawUs=200),
                       lambda r:r['samples'][0].update(playing=True)):
            row=observation('pausedEOF');modify(row)
            with self.assertRaises(ValueError): validate_observation(row,'pausedEOF',42)


if __name__=='__main__': unittest.main()
