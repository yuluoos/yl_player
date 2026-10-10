import copy
import math
import unittest
from test_stop_boundary import cells
from summarize_stop_timing import validate_timing_pair


def timed_cells():
    cs=cells()
    for c in cs:
        mode=c['result']['boundaryMode'];base=100 if mode=='stop' else 0
        wait=2 if mode=='stop' else 30
        action=10 if mode=='stop' else 0
        values=[9,9,9+wait,9+wait,9+wait+action,10+wait+action,10+wait+action,10+wait+action,10+wait+action,11+wait+action]
        keys=['ackReturned','sleepStarted','sleepFinished','actionStarted','actionFinished','assertionsFinished','probeEntered','recorderSettled','memoryReadFinished','rowCaptured']
        timing=dict(zip(keys,[base+x for x in values]))
        for i,r in enumerate(c['rows']):
            r.update(timingProfile='long-hold-v1',boundaryTiming=copy.deepcopy(timing) if i>=3 else {})
            if i>=3:r.update(uptime=timing['rowCaptured']+(i-3)*4,interventionWaitSeconds=wait)
        c['result']['stopTiming']=True
        for p in c['result']['probes']:
            row=next(r for r in c['rows'] if r['phase']==p['phase'])
            p.update(startedUptime=row['uptime']+.1,endedUptime=row['uptime']+.5)
    return cs


class StopTimingTests(unittest.TestCase):
    def test_segments_bind_to_rows_and_long_control_covers_stop(self):
        r=validate_timing_pair(timed_cells())
        self.assertTrue(r['longerWaitControlCoversStop'])
        self.assertIsNone(r['timings'][0]['nativeStopSeconds'])
        self.assertEqual(r['timings'][1]['nativeStopSeconds'],10)
        for t in r['timings']:self.assertAlmostEqual(sum(t['segments'].values()),t['totalSeconds'])

    def test_rejects_missing_nonfinite_unordered_or_mutated_timing(self):
        changes=[lambda c:c[1]['rows'][3]['boundaryTiming'].pop('actionStarted'),
            lambda c:c[1]['rows'][3]['boundaryTiming'].update(actionFinished=math.nan),
            lambda c:c[1]['rows'][3]['boundaryTiming'].update(actionFinished=0),
            lambda c:c[1]['rows'][3]['boundaryTiming'].update(rowCaptured=120),
            lambda c:c[1]['rows'][4]['boundaryTiming'].update(actionFinished=115),
            lambda c:c[0]['rows'][3].update(interventionWaitSeconds=2),
            lambda c:c[0]['rows'][3].update(timingProfile='short-hold-v1'),
            lambda c:c[0]['result'].update(stopTiming=False),
            lambda c:c[0]['rows'][2].update(boundaryTiming={'ackReturned':1})]
        for change in changes:
            c=timed_cells();change(c)
            with self.subTest(change=change),self.assertRaises(ValueError):validate_timing_pair(c)

    def test_uncovered_stop_does_not_claim_time_control(self):
        cs=timed_cells();c=cs[1]
        for row in c['rows'][3:]:
            row['uptime']+=30
            for k in ['actionFinished','assertionsFinished','probeEntered','recorderSettled','memoryReadFinished','rowCaptured']:row['boundaryTiming'][k]+=30
        for p in c['result']['probes'][2:]:p['startedUptime']+=30;p['endedUptime']+=30
        self.assertFalse(validate_timing_pair(cs)['longerWaitControlCoversStop'])
