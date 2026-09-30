import copy
import unittest
from resources import summarize_trials, summarize_disposed_memory
from test_resources import sample, trial


def control():
    t=trial([sample(1,1,'disposed'),sample(1000001,2,'disposed')])
    t.update(schemaVersion=2,workload='harness-only',buildMode='profile',engine='unknown',decoder='unknown')
    return t


class WorkloadTests(unittest.TestCase):
    def test_control_is_explicit_and_never_playback_evidence(self):
        r=summarize_trials([control()])
        self.assertEqual(r['workload'],'harness-only')
        self.assertEqual(r['trials'][0]['workload'],'harness-only')
        self.assertFalse(r['performanceBaseline'])
        self.assertEqual(summarize_disposed_memory([control()])['workload'],'harness-only')

    def test_legacy_and_new_playback_are_labelled(self):
        old=trial([sample(1,1)])
        new=dict(old,schemaVersion=2,workload='playback')
        for t in (old,new): self.assertEqual(summarize_trials([t])['workload'],'playback')

    def test_mixed_workloads_or_schemas_rejected(self):
        a=control();a['plannedAttempts']=2
        for changes in (dict(schemaVersion=2,workload='playback'),dict(schemaVersion=1)):
            b=copy.deepcopy(a);b.update(attempt=2,**changes)
            if b['schemaVersion']==1: del b['workload']
            with self.assertRaises(ValueError): summarize_trials([a,b])

    def test_invalid_control_identity_and_schema_rejected(self):
        for changes in (dict(workload='other'),dict(buildMode='debug'),dict(engine='managedFallback'),dict(decoder='hardware'),dict(schemaVersion=True),dict(schemaVersion=3)):
            with self.assertRaises(ValueError): summarize_trials([dict(control(),**changes)])
        t=control();del t['workload']
        with self.assertRaises(ValueError): summarize_trials([t])
        t=control();t['schemaVersion']=1
        with self.assertRaises(ValueError): summarize_trials([t])

if __name__=='__main__': unittest.main()
