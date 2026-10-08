import copy
import unittest
from run_audio_tail_continuity import validate


def row(scenario):
    n=2000 if scenario=='steady' else 100
    return dict(scenario=scenario,pid=42,accepted=n,drained=True,pending=0,ledgerBytes=0,ledgerPeak=196608,
        marker=dict(frames=n*1024,errors=[],interiorZeroFrames=0 if scenario=='steady' else 4800),
        submissions=[dict(ordinal=i,playedBack=i==n if scenario=='steady' else i>=40) for i in range(1,n+1)],
        events=[dict(ordinal=i,playedBack=i==n if scenario=='steady' else i>=40) for i in range(1,n+1)],
        samples=[dict(rawUs=t,pending=24,bytes=196608,ledgerBytes=196608,durationUs=511992) for t in range(0,200001,10000)],
        fallbackCount=0 if scenario=='steady' else 1,
        actions=[] if scenario=='steady' else [dict(name='starved',rawUs=10000),dict(name='fallback',rawUs=110000),dict(name='refill',rawUs=150000)])


class AudioTailContinuityTests(unittest.TestCase):
    def test_accepts_exact_continuity_and_compatible_fallback(self):
        for scenario in ('steady','starve'):self.assertEqual(validate(row(scenario),scenario,42)['buffers'],row(scenario)['accepted'])

    def test_rejects_lost_reordered_or_silent_interior_frames(self):
        for change in (lambda r:r['marker'].update(frames=1),lambda r:r['marker'].update(errors=['duplicate']),
                       lambda r:r['marker'].update(interiorZeroFrames=1)):
            r=row('steady');change(r)
            with self.assertRaises(ValueError):validate(r,'steady',42)

    def test_rejects_missing_callbacks_and_ledger_overrun(self):
        for change in (lambda r:r['events'].pop(),lambda r:r.update(ledgerPeak=196609),
                       lambda r:r['samples'][0].update(ledgerBytes=196609),lambda r:r.update(drained=False)):
            r=row('steady');change(r)
            with self.assertRaises(ValueError):validate(r,'steady',42)

    def test_requires_one_way_fallback_at_bounded_observed_time(self):
        for change in (lambda r:r.update(fallbackCount=0),lambda r:r['actions'][1].update(rawUs=90000),
                       lambda r:r['actions'][1].update(rawUs=125000),lambda r:r['submissions'][-1].update(playedBack=False)):
            r=row('starve');change(r)
            with self.assertRaises(ValueError):validate(r,'starve',42)

    def test_rejects_large_poll_gaps(self):
        r=row('steady');r['samples'][1]['rawUs']=60000
        with self.assertRaises(ValueError):validate(r,'steady',42)


if __name__=='__main__':unittest.main()
