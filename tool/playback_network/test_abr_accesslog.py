import copy
import unittest
from unittest.mock import patch
from abr_accesslog import cleanup_owned
from abr_accesslog import summarize

class AccessLogTests(unittest.TestCase):
    def rows(self):
        return [dict(elapsed=i,position=i,rate=0 if i==3 else 1,status=1,width=w,height=180,
                     peak=0,forwardBuffer=10,completed=i==3,framesPublished=i,
                     logs=[dict(observedBitrate=600000,indicatedBitrate=414000)])
                for i,w in enumerate((320,640,320,320))]

    def test_preserves_downshift_without_claiming_recovery_or_cause(self):
        result=summarize(self.rows())
        self.assertEqual(result['geometryWidths'],[320,640,320])
        self.assertFalse(result['upshiftAfterDownshiftObserved'])
        self.assertEqual(result['lastObservedBitrate'],600000)
        self.assertFalse(result['internalABRDecisionVerified'])

    def test_detects_recovered_output_but_never_admits_capability(self):
        rows=self.rows();rows[-1]['width']=640
        result=summarize(rows)
        self.assertTrue(result['upshiftAfterDownshiftObserved'])
        self.assertFalse(result['capabilityAccepted'])

    def test_missing_completion_frames_invalid_time_and_nonzero_cap_fail(self):
        variants=[[]]
        for key,value in [('completed',False),('framesPublished',0),('elapsed',float('nan')),('peak',1)]:
            rows=self.rows();rows[-1][key]=value;variants.append(rows)
        for rows in variants:
            with self.subTest(rows=rows),self.assertRaises(ValueError):summarize(rows)

if __name__=='__main__':unittest.main()

class CleanupTests(unittest.TestCase):
    def test_missing_and_changed_identity_never_signals(self):
        for current in ('', 'different executable/start time'):
            with patch('abr_accesslog.process_identity', return_value=current), patch('abr_accesslog.os.kill') as kill:
                self.assertEqual(cleanup_owned((123, 'original')), current == '')
                kill.assert_not_called()

    def test_matching_identity_is_terminated_and_verified(self):
        with patch('abr_accesslog.process_identity', side_effect=['original', '']), patch('abr_accesslog.os.kill') as kill:
            self.assertTrue(cleanup_owned((123, 'original')))
            kill.assert_called_once()
