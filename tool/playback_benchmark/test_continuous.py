import copy
import unittest
from continuous import summarize_continuous
from test_resources import sample


def rows():
    result=[]
    for n in range(241):
        result.append(dict(schemaVersion=1,runId='continuous-test',pid=42,sequence=n,
            kind='tick',sessionId='session-1',positionUs=n*5000000,status='playing',
            failure=False,engine='managedFallback',decoder='hardware',audioSelected=True,
            videoPresent=True,resource=sample(1+n*5000000,1+n*100000,'playing')))
    result.append(dict(schemaVersion=1,runId='continuous-test',pid=42,sequence=241,
        kind='result',outcome='passed',cleaned=True,errorType=None,disposedSamples=[sample(1201000001,25000000,'disposed'),sample(1203000001,25000100,'disposed')]))
    return result


class ContinuousTests(unittest.TestCase):
    def test_complete_single_session_and_weighted_resources(self):
        r=summarize_continuous(rows(),'continuous-test')
        self.assertTrue(r['complete'])
        self.assertEqual(r['playbackWallUs'],1200000000)
        self.assertEqual(r['sampleCount'],241)
        self.assertFalse(r['performanceBaseline'])

    def test_disposed_observation_is_not_a_second_failed_playback_trial(self):
        r=summarize_continuous(rows(),'continuous-test')
        self.assertNotIn('outcome',r['disposed'])

    def test_interrupted_run_retains_observed_denominator(self):
        r=summarize_continuous(rows()[:17],'continuous-test')
        self.assertFalse(r['complete'])
        self.assertEqual(r['observedTicks'],17)
        self.assertEqual(r['outcome'],'unobserved')

    def test_reload_stall_gap_failure_and_cleanup_cannot_pass(self):
        for field,value in [('sessionId','replacement'),('positionUs',0),('failure',True),
                            ('audioSelected',False),('status','buffering')]:
            data=rows();data[120][field]=value
            self.assertFalse(summarize_continuous(data,'continuous-test')['complete'],field)
        data=rows();data[-1]['cleaned']=False
        self.assertFalse(summarize_continuous(data,'continuous-test')['complete'])
        data=rows();data[120]['resource']['monotonicUs']+=4000000
        self.assertFalse(summarize_continuous(data,'continuous-test')['complete'])

    def test_forged_identity_sequence_clock_and_unavailable_rejected(self):
        for field,value in [('pid',43),('sequence',5),('runId','other')]:
            data=rows();data[10][field]=value
            with self.assertRaises(ValueError):summarize_continuous(data,'continuous-test')
        data=rows();data[10]['resource']['monotonicUs']=1
        with self.assertRaises(ValueError):summarize_continuous(data,'continuous-test')
        data=rows();data[10]['resource'].update(status='unavailable',cpuUs=None,rssBytes=None,footprintBytes=None)
        self.assertFalse(summarize_continuous(data,'continuous-test')['complete'])

    def test_missing_short_or_duplicate_terminal_is_not_success(self):
        for data in [rows()[:-1],rows()[:20]+[dict(rows()[-1],sequence=20)]]:
            self.assertFalse(summarize_continuous(data,'continuous-test')['complete'])
        with self.assertRaises(ValueError):summarize_continuous(rows()+[rows()[-1]],'continuous-test')
