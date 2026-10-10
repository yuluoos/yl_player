import copy
import unittest
from test_stop_timing import timed_cells
from run_audio_integration_resources import validate_stop_rows
from summarize_stop_timing import validate_timing_rows
from summarize_stop_paths import validate_paths


def cells():
    legacy=timed_cells()[1];candidate=copy.deepcopy(legacy);candidate['arm']='candidate'
    for i,r in enumerate(candidate['rows']):
        r.update(candidate=True,submissionAnchor=i<4,pid=r['pid']+1,uptime=r['uptime']+100)
        r['modes'].update(playedSubmissions=1,renderedSubmissions=2812)
        r['boundaryTiming']={k:v+100 for k,v in r['boundaryTiming'].items()}
    for p in candidate['result']['probes']:p['startedUptime']+=100;p['endedUptime']+=100
    return [legacy,candidate]


class StopPathTests(unittest.TestCase):
    def test_candidate_preserves_real_mode_and_anchor(self):
        r=cells()[1]['rows']
        try:
            result=validate_stop_rows(r,'stop',60,'decoded-60.mkv',candidate=True)
            timing=validate_timing_rows(r,'stop',candidate=True)
        except ValueError as error:self.fail('Candidate stop is not accepted: '+str(error))
        self.assertEqual(result['modes']['renderedSubmissions'],2812)
        self.assertEqual(timing['nativeStopSeconds'],10)

    def test_two_paths_are_reported_without_admission(self):
        r=validate_paths(cells())
        self.assertEqual([c['arm'] for c in r['cells']],['legacy','candidate'])
        self.assertFalse(r['productionAdmission'])
        self.assertEqual(r['candidateMinusLegacyStopSeconds'],0)

    def test_rejects_fallback_wrong_modes_build_process_or_missing_heap(self):
        changes=[lambda c:c.pop(),lambda c:c[1].update(arm='legacy'),
            lambda c:c[1].update(identity={'other':1}),lambda c:c[1]['result'].update(boundaryMode='hold'),
            lambda c:c[1]['result'].update(complete=False),lambda c:c[1]['result']['probes'].pop(),
            lambda c:c[1]['rows'][3].update(submissionAnchor=False),
            lambda c:c[1]['rows'][1]['modes'].update(playedSubmissions=2813,renderedSubmissions=0),
            lambda c:[r.update(pid=c[0]['rows'][0]['pid']) for r in c[1]['rows']],
            lambda c:[r.update(uptime=r['uptime']-100) for r in c[1]['rows']]]
        for change in changes:
            c=cells();change(c)
            with self.subTest(change=change),self.assertRaises(ValueError):validate_paths(c)
