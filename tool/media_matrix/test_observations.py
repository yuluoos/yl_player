"""Acceptance must preserve the planned denominator and output provenance."""
import copy
import unittest
from observations import summarize


class ObservationsTest(unittest.TestCase):
    def setUp(self):
        self.cases = [dict(id='mp4-avc-aac', sha256='a'*64, integrity='valid', supportRequirement='required'),
                      dict(id='ps-mpeg2-mp3', sha256='b'*64, integrity='valid', supportRequirement='diagnostic')]
        self.plan = dict(runId='run-1', buildSha256='c'*64, platform='android',
                         planned=[dict(caseId=c['id'], transport='file') for c in self.cases])
        self.rows = [dict(**p, runId='run-1', buildSha256='c'*64, platform='android', mediaHash=c['sha256'],
                          supportRequirement=c['supportRequirement'], outcome='passed', firstFrame=True,
                          seekProgress=True, completed=True, disposed=True, pixelMarkersVerified=True,
                          pcmMarkersVerified=True, pixelVerificationMethod='player-composition',
                          pcmVerificationMethod='native-player-pcm', audioClockUs=1000000)
                     for p,c in zip(self.plan['planned'], self.cases)]

    def result(self): return summarize(self.plan, self.rows, self.cases)
    def test_complete_required_output_is_separate_from_diagnostics(self):
        self.rows[1]['outcome']='failed'
        result=self.result()
        self.assertTrue(result['fullAcceptance'])
        self.assertEqual((1,1,1), (result['requiredRows'],result['supportedRows'],result['diagnosticRows']))
    def test_missing_planned_row(self):
        self.rows.pop(); self.assertFalse(self.result()['fullAcceptance'])
    def test_duplicate_row(self):
        self.rows.append(copy.deepcopy(self.rows[0])); self.assertFalse(self.result()['fullAcceptance'])
    def test_hash_and_run_identity_cannot_be_borrowed(self):
        for key in ['mediaHash','buildSha256','runId','platform']:
            with self.subTest(key=key):
                rows=copy.deepcopy(self.rows); rows[0][key]='wrong'
                self.assertFalse(summarize(self.plan,rows,self.cases)['fullAcceptance'])
    def test_lifecycle_is_not_output(self):
        for key in ['pixelMarkersVerified','pcmMarkersVerified','disposed']:
            rows=copy.deepcopy(self.rows);rows[0][key]=False
            self.assertFalse(summarize(self.plan,rows,self.cases)['fullAcceptance'])
    def test_skipped_required_software_row_stays_in_denominator(self):
        self.rows[0].update(outcome='skipped',decoder='software')
        result=self.result();self.assertEqual(1,result['requiredRows']);self.assertEqual(0,result['supportedRows'])
        self.assertFalse(result['fullAcceptance'])
    def test_host_decode_cannot_verify_player_output(self):
        self.rows[0]['pixelVerificationMethod']='host-ffmpeg'
        self.assertFalse(self.result()['playerOutputVerified'])
    def test_case_classification_cannot_be_changed(self):
        self.rows[0]['supportRequirement']='diagnostic'
        self.assertFalse(self.result()['fullAcceptance'])
    def test_empty_or_duplicate_plan_cannot_accept(self):
        for planned in [[],self.plan['planned']*2]:
            plan=dict(self.plan,planned=planned)
            self.assertFalse(summarize(plan,self.rows,self.cases)['fullAcceptance'])
    def test_invalid_or_missing_audio_clock(self):
        for clock in [None,-1,True,'100']:
            self.rows[0]['audioClockUs']=clock
            self.assertFalse(self.result()['fullAcceptance'])
    def test_truncated_input_is_a_negative_control_not_support(self):
        self.cases[0]['integrity']='truncated';self.rows[0].update(outcome='failed',category='container',firstFrame=False)
        result=self.result();self.assertEqual(0,result['supportedRows']);self.assertEqual(1,result['negativeControls'])
    def test_unplanned_row_cannot_inflate_support(self):
        self.rows.append(dict(self.rows[0],transport='http'))
        self.assertFalse(self.result()['fullAcceptance'])

if __name__ == '__main__': unittest.main()
