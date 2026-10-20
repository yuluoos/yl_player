import copy
import unittest
from stress_resources import attach
from test_performance_gate import run_fixture

class StressResourcesTests(unittest.TestCase):
    def rows(self, run):
        trials=[]
        for t in run['trials']:
            base=t['attempt']*10000000
            samples=[]
            for i,phase in enumerate(['idle','opening','playing','playing','disposing','disposed','disposed']):
                samples.append(dict(phase=phase,monotonicUs=base+i*250000,cpuUs=i*50000,
                    rssBytes=100+i,footprintBytes=80+i,power='ac',thermal='nominal',status='ok'))
            trials.append(dict(schemaVersion=1,runId=run['runId'],attempt=t['attempt'],plannedAttempts=run['plannedAttempts'],pid=123,
                buildMode='profile',intervalMs=250,engine='unknown',decoder='unknown',outcome=t['outcome'],samples=samples))
        return trials
    def test_observed_resources_and_conditions_join_without_epoch_subtraction(self):
        run=run_fixture();rows=self.rows(run);result,summary=attach(run,rows)
        self.assertEqual(result['trials'][0]['values']['cpuPlayingPercent'],20)
        self.assertEqual(result['trials'][0]['values']['rssPeakBytes'],106)
        self.assertEqual(result['trials'][0]['values']['rssDisposedBytes'],106)
        self.assertEqual(result['conditions']['thermal'],'nominal')
        self.assertEqual(summary['trials'][0]['phases']['playing']['sampledWindowUs'],250000)
    def test_identity_outcome_and_missing_trials_fail(self):
        run=run_fixture();rows=self.rows(run)
        for key,value in [('runId','other'),('attempt',99),('outcome','timeout')]:
            bad=copy.deepcopy(rows);bad[0][key]=value
            with self.assertRaises(ValueError):attach(run,bad)
        with self.assertRaises(ValueError):attach(run,rows[:-1])
    def test_missing_observations_stay_null_and_mixed_power_unknown(self):
        run=run_fixture();rows=self.rows(run)
        for r in rows[0]['samples']:
            r.update(status='unavailable',cpuUs=None,rssBytes=None,footprintBytes=None)
        rows[-1]['samples'][-1]['power']='battery'
        result,_=attach(run,rows)
        self.assertIsNone(result['trials'][0]['values']['rssPeakBytes'])
        self.assertEqual(result['conditions']['power'],'unknown')
