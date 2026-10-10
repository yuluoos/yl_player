import copy
import unittest
from display_timing import diagnose_timing


def observations():
    event=dict(sequence=1,kind='mainQueue',start=1.0,end=1.16,seconds=.16)
    base=dict(enabled=True,stopped=False,total=1,counts=dict(tickGap=0,tickWork=0,mainQueue=1,producerGap=0),
        events=[event],maxima=dict(tickGap=0,tickWork=0,mainQueue=.16,producerGap=0),tickCalls=10,probeSent=2,probeCompleted=1,probeCancelled=0,probePending=True,probeSkipped=1)
    drop=dict(reason='catchUp',total=1,uptime=1.15,previousTickUptime=1.0)
    later=copy.deepcopy(base);later.update(stopped=True,probePending=False,probeCancelled=1)
    return [dict(phase='playing',uptime=2,timingDiagnostics=base,dropDiagnostics=dict(events=[drop])),
            dict(phase='disposed',uptime=3,timingDiagnostics=later,dropDiagnostics=dict(events=[drop]))]


class DisplayTimingTests(unittest.TestCase):
    def test_correlates_overlap_without_claiming_root_cause(self):
        r=diagnose_timing(observations())
        self.assertEqual(r['correlations'],[dict(dropTotal=1,reason='catchUp',firstObservedPhase='playing',timingSequences=[1])])
        self.assertFalse(r['rootCauseProven'])
        self.assertFalse(r['productionAdmission'])
        self.assertEqual(r['counts']['mainQueue'],1)

    def test_rejects_missing_nonmonotonic_and_inconsistent_evidence(self):
        for mutate in [lambda r:r[0].pop('timingDiagnostics'),
                       lambda r:r[0]['timingDiagnostics'].update(enabled=False),
                       lambda r:r[0]['timingDiagnostics'].pop('maxima'),
                       lambda r:r[0]['timingDiagnostics']['maxima'].update(mainQueue=.01),
                       lambda r:r[0]['timingDiagnostics'].update(probeCompleted=0,probeSent=1),
                       lambda r:r[0]['timingDiagnostics'].update(probeSent=5),
                       lambda r:r[0]['timingDiagnostics']['counts'].update(tickWork=1),
                       lambda r:r[0]['timingDiagnostics']['events'][0].update(end=.5),
                       lambda r:r[0]['timingDiagnostics']['events'][0].update(seconds=.5),
                       lambda r:r[1]['timingDiagnostics'].update(tickCalls=0),
                       lambda r:r[1]['timingDiagnostics']['events'][0].update(start=.9,seconds=.26)]:
            r=observations();mutate(r)
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):diagnose_timing(r)

    def test_evicted_history_is_not_absence_proof_and_stop_freezes(self):
        r=observations()
        for row in r:
            d=row['timingDiagnostics'];d['total']=35;d['counts']['mainQueue']=35;d['probeSent']=36;d['probeCompleted']=35;d['maxima']['mainQueue']=.1
            d['events']=[dict(sequence=i,kind='mainQueue',start=1+i/1000,end=1.1+i/1000,seconds=.1) for i in range(4,36)]
        report=diagnose_timing(r)
        self.assertEqual(report['firstRetainedSequence'],4)
        self.assertTrue(report['historyTruncated'])
        after=copy.deepcopy(r[-1]);after['uptime']=4;after['timingDiagnostics']['probeSkipped']+=1;r.append(after)
        with self.assertRaises(ValueError):diagnose_timing(r)

    def test_diagnostic_short_cannot_admit_uninstrumented_long(self):
        import json,tempfile
        from pathlib import Path
        from test_decoded_continuity import rows
        from run_decoded_continuity import require_short_gate
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);identity=dict(sourceHashes={},binaryHashes={})
            (p/'identity.json').write_text(json.dumps(identity))
            (p/'result.json').write_text(json.dumps(dict(complete=True,kind='short',exitCode=0,timingDiagnostics=True)))
            (p/'rows.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows()))
            with self.assertRaises(ValueError):require_short_gate(p,identity)

if __name__=='__main__':unittest.main()
