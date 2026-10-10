import copy
import unittest
from test_decoded_eof_resources import rows
from run_audio_integration_resources import validate_stop_rows


def boundary_rows(mode):
    r=rows(False)
    mid=copy.deepcopy(r[2]);mid['phase']='intervened';r.insert(3,mid)
    for i,row in enumerate(r):
        row.update(uptime=i*4,fixtureName='decoded-60.mkv',playbackElapsedSeconds=60,
            retainedDeltaCount=0,retainedOrderCount=0,retainedEventCount=10,
            callbackWrapping='transparent',callbackObservation='unobserved',boundaryMode=mode,
            playerStopCalls=int(mode=='stop' and i>=3),attachedNodeCount=4 if i<4 else 2,
            playerAttached=i<4,graphUnchanged=i<4,interventionWaitSeconds=2 if i>=3 else 0,
            publicDeltaCount=100 if i else 1)
        row['modes'].update(playedSubmissions=2813,playedCallbacks=None,renderedCallbacks=None)
    return r


class StopBoundaryTests(unittest.TestCase):
    def test_accepts_hold_and_stop_without_inventing_callbacks(self):
        for mode in ('hold','stop'):
            self.assertFalse(validate_stop_rows(boundary_rows(mode),mode,60,'decoded-60.mkv')['nativeCallbackCountsObserved'])

    def test_rejects_early_teardown_wrong_intervention_or_missing_phase(self):
        changes=[lambda r:r.pop(3),lambda r:r[3].update(playerStopCalls=0),
            lambda r:r[2].update(playerStopCalls=1),lambda r:r[3].update(engineRunning=False),
            lambda r:r[3].update(graphUnchanged=False),lambda r:r[3].update(playerAttached=False),
            lambda r:r[3].update(attachedNodeCount=3),lambda r:r[3].update(interventionWaitSeconds=1),
            lambda r:r[3].update(uptime=r[2]['uptime']-1),lambda r:r[4].update(playerAttached=True),
            lambda r:r[3]['modes'].update(playedSubmissions=2814),
            lambda r:r[3].update(publicDeltaCount=101),lambda r:r[3].update(boundaryMode='hold'),
            lambda r:r[3].update(completed=2),lambda r:r[3].update(pending=True)]
        for change in changes:
            r=boundary_rows('stop');change(r)
            with self.subTest(change=change),self.assertRaises(ValueError):validate_stop_rows(r,'stop',60,'decoded-60.mkv')

    def test_hold_cannot_stop_and_formal_requires_fixture_count(self):
        r=boundary_rows('hold');r[3]['playerStopCalls']=1
        with self.assertRaises(ValueError):validate_stop_rows(r,'hold',60,'decoded-60.mkv')
        r=boundary_rows('stop')
        for row in r:row['modes']['playedSubmissions']=2812
        with self.assertRaises(ValueError):validate_stop_rows(r,'stop',60,'decoded-60.mkv')

from summarize_stop_boundary import validate_pair


def cells():
    output=[]
    for mode in ('hold','stop'):
        r=boundary_rows(mode)
        if mode=='stop':
            for row in r:row['pid']+=1;row['uptime']+=100
        output.append(dict(rows=r,identity={'hash':'same'},arm='legacy',seconds=60,
            result=dict(boundaryMode=mode,callbackWrapping='transparent',complete=True,testExitCode=0,errors=[],
                probes=[dict(phase=p,valid=True,summaryTotals=[10,100]) for p in ('configured','drained','intervened','disposed')]),
            selected={p:{'lifecycle':None} for p in ('configured','drained','intervened','disposed')}))
    return output


class StopPairTests(unittest.TestCase):
    def test_reports_both_arms_and_preserves_missing_types(self):
        result=validate_pair(cells())
        self.assertEqual(len(result['cells']),2)
        self.assertIsNone(result['cells'][0]['selected']['drained']['lifecycle'])
        self.assertFalse(result['downstreamBoundProven'])

    def test_rejects_failed_mixed_reused_overlapping_or_incomplete_pair(self):
        changes=[lambda c:c.pop(),lambda c:c[1].update(identity={'hash':'other'}),
            lambda c:c[1]['result'].update(complete=False),lambda c:c[1]['result'].update(boundaryMode='hold'),
            lambda c:[r.update(pid=42) for r in c[1]['rows']],
            lambda c:[r.update(uptime=r['uptime']-100) for r in c[1]['rows']],
            lambda c:c[1]['result']['probes'].pop(),lambda c:c[1].update(seconds=30)]
        for change in changes:
            c=cells();change(c)
            with self.subTest(change=change),self.assertRaises(ValueError):validate_pair(c)
