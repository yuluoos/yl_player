import copy
import unittest
from display_timing import diagnose_cadence_boundary


class CadenceBoundaryTests(unittest.TestCase):
    def rows(self):
        return [dict(phase='playing',uptime=1.13,timingDiagnostics=dict(enabled=True,stopped=False,
            cadenceBoundary=dict(calls=2,total=1,maxima=dict(entryGap=.08,refreshWork=.04,bodyWork=.005),events=[
                dict(sequence=1,previousEntry=1.,entry=1.08,body=1.12,end=1.125,entryGap=.08,
                     refreshWork=.04,bodyWork=.005,mainResponses=[dict(requested=1.02,delivered=1.021)])])),
            dropDiagnostics=dict(events=[dict(total=1,previousTickUptime=1.002,uptime=1.12,reason='catchUp')]))]

    def test_separates_pre_entry_gap_refresh_and_body(self):
        result=diagnose_cadence_boundary(self.rows())
        self.assertEqual(result['correlations'][0]['cadenceSequences'],[1])
        self.assertEqual(result['events'][0]['mainResponses'],[dict(requested=1.02,delivered=1.021)])
        self.assertFalse(result['rootCauseProven'])

    def test_rejects_corrupt_boundaries(self):
        for field,value in [('entryGap',.04),('refreshWork',.08),('bodyWork',.4),('body',1.07),('end',1.2)]:
            with self.subTest(field=field):
                rows=self.rows();rows[0]['timingDiagnostics']['cadenceBoundary']['events'][0][field]=value
                with self.assertRaises(ValueError):diagnose_cadence_boundary(rows)

    def test_rejects_changed_history_unbounded_responses_and_stop_mutation(self):
        rows=self.rows();later=copy.deepcopy(rows[0]);later['uptime']=2
        later['timingDiagnostics']['cadenceBoundary']['events'][0]['mainResponses']=[]
        with self.assertRaises(ValueError):diagnose_cadence_boundary(rows+[later])
        rows=self.rows();rows[0]['timingDiagnostics']['cadenceBoundary']['events'][0]['mainResponses']*=17
        with self.assertRaises(ValueError):diagnose_cadence_boundary(rows)
        rows=self.rows();rows[0]['timingDiagnostics']['stopped']=True
        later=copy.deepcopy(rows[0]);later['uptime']=2;later['timingDiagnostics']['cadenceBoundary']['calls']=3
        with self.assertRaises(ValueError):diagnose_cadence_boundary(rows+[later])

    def test_runloop_history_rejects_out_of_window_and_unbounded_samples(self):
        rows=self.rows();event=rows[0]['timingDiagnostics']['cadenceBoundary']['events'][0]
        event.update(runLoop=[dict(uptime=1.01,activity=32),dict(uptime=1.079,activity=64)],runLoopHistoryTruncated=True)
        self.assertEqual(len(diagnose_cadence_boundary(rows)['events'][0]['runLoop']),2)
        for activity,uptime in [(3,1.01),(64,1.2),(64,-1)]:
            with self.subTest(activity=activity,uptime=uptime):
                invalid=copy.deepcopy(rows);invalid[0]['timingDiagnostics']['cadenceBoundary']['events'][0]['runLoop'][0]=dict(activity=activity,uptime=uptime)
                with self.assertRaises(ValueError):diagnose_cadence_boundary(invalid)
        event['runLoop']*=129
        with self.assertRaises(ValueError):diagnose_cadence_boundary(rows)
