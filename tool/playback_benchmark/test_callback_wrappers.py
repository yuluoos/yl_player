import copy
import unittest
from test_decoded_eof_resources import rows
from summarize_callback_wrappers import validate_wrappers


def cells():
    output=[]
    for arm in ('legacy','candidate'):
        for wrapping in ('wrapped','transparent'):
            r=rows(arm=='candidate')
            for row in r:
                row['pid']+=len(output);row['uptime']+=100*len(output)
                row.update(callbackWrapping=wrapping,callbackObservation='unobserved' if wrapping=='transparent' else 'native-wrapped',
                    fixtureName='decoded-60.mkv',playbackElapsedSeconds=60,
                    retainedDeltaCount=0,retainedOrderCount=0,retainedEventCount=10)
                row['modes']=dict(playedSubmissions=1 if arm=='candidate' else 2813,
                    renderedSubmissions=2812 if arm=='candidate' else 0,
                    playedCallbacks=None if wrapping=='transparent' else (1 if arm=='candidate' else 2813),
                    renderedCallbacks=None if wrapping=='transparent' else (2812 if arm=='candidate' else 0))
            output.append(dict(arm=arm,seconds=60,identity={'hash':'same'},rows=r,
                result=dict(callbackWrapping=wrapping,complete=True,testExitCode=0,errors=[],
                    probes=[dict(phase=p,valid=True,summaryTotals=[10,100]) for p in ('configured','drained','disposed')]),
                selected={p:{} for p in ('configured','drained','disposed')}))
    return output


class CallbackWrapperTests(unittest.TestCase):
    def test_four_cells_preserve_unobserved_counts(self):
        result=validate_wrappers(cells())
        self.assertEqual(len(result['cells']),4)
        self.assertEqual([c['nativeCallbackCountsObserved'] for c in result['cells']],[True,False,True,False])
        self.assertFalse(result['downstreamBoundProven'])

    def test_rejects_duplicate_wrong_build_failed_or_unequal_submissions(self):
        changes=(lambda c:c.pop(),lambda c:c.append(copy.deepcopy(c[0])),
            lambda c:c[1].update(identity={'hash':'different'}),
            lambda c:c[1]['result'].update(complete=False),
            lambda c:[r['modes'].update(playedSubmissions=2812) for r in c[1]['rows']])
        for change in changes:
            c=cells();change(c)
            with self.assertRaises(ValueError):validate_wrappers(c)

    def test_rejects_reused_process_or_overlapping_windows(self):
        for overlap in (False,True):
            c=cells()
            for row in c[1]['rows']:
                if overlap:row['uptime']-=100
                else:row['pid']=c[0]['rows'][0]['pid']
            with self.assertRaises(ValueError):validate_wrappers(c)
