import copy
import unittest
from test_decoded_eof_resources import rows
from summarize_decoded_resource_matrix import validate_matrix


def cells():
    result=[]
    for seconds,count in ((4,188),(30,1407),(60,2813)):
        for arm in ('legacy','candidate'):
            data=rows(arm=='candidate')
            for row in data:
                row.update(fixtureName=f'decoded-{seconds}.mkv', playbackElapsedSeconds=seconds,
                           retainedDeltaCount=0, retainedOrderCount=0, retainedEventCount=8,
                           rssBytes=1000, footprintBytes=900, ledgerPeak=100)
                row['modes']=dict(renderedSubmissions=count-1 if arm=='candidate' else 0,
                    renderedCallbacks=count-1 if arm=='candidate' else 0,
                    playedSubmissions=1 if arm=='candidate' else count,
                    playedCallbacks=1 if arm=='candidate' else count)
            result.append(dict(arm=arm,seconds=seconds,rows=data,identity={'hash':'same'},
                result=dict(complete=True,testExitCode=0,errors=[],probes=[dict(phase=p,valid=True,summaryTotals=[10,100])
                for p in ('configured','drained','disposed')])))
    return result


class DecodedResourceMatrixTests(unittest.TestCase):
    def test_accepts_complete_matrix_without_proving_bound(self):
        value=validate_matrix(cells())
        self.assertEqual(len(value['cells']),6)
        self.assertFalse(value['downstreamBoundProven'])
        self.assertEqual(value['cells'][0]['resources']['disposedLater']['ledgerBytes'],0)
        self.assertEqual(value['cells'][0]['resources']['drained']['rssBytes'],1000)
        self.assertEqual(value['cells'][0]['modes']['playedCallbacks'],188)

    def test_rejects_missing_duplicate_failed_and_different_build(self):
        for change in (lambda c:c.pop(),lambda c:c.append(copy.deepcopy(c[0])),
                       lambda c:c[1]['result'].update(complete=False),
                       lambda c:c[1].update(identity={'hash':'different'})):
            c=cells();change(c)
            with self.assertRaises(ValueError):validate_matrix(c)

    def test_rejects_short_replayed_as_long_and_unequal_arm_counts(self):
        for changes in ((2,3),(3,)):
            c=cells()
            for index in changes:
                for row in c[index]['rows']:
                    row['modes']=copy.deepcopy(c[index%2]['rows'][1]['modes'])
            with self.assertRaises(ValueError):validate_matrix(c)
