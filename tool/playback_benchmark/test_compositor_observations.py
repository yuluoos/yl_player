import unittest
from compositor_observations import measure
class CompositorTests(unittest.TestCase):
    def fixture(self):
        trial=dict(startUs=1000000,seekStartUs=2000000,session='owned',targetUs=5000000)
        rows=[dict(displayUs=900000,receivedUs=901000,frame=None),dict(displayUs=1100000,receivedUs=1101000,frame=0)]
        rows += [dict(displayUs=2100000+i*100000,receivedUs=2101000+i*100000,frame=50+i) for i in range(12)]
        return trial,rows
    def test_observed_frames_use_display_clock_not_callback_receipt(self):
        trial,rows=self.fixture();out=measure(trial,rows)
        self.assertEqual(out['firstCompositorUs'],100000)
        self.assertEqual(out['seekFirstCompositorUs'],100000)
        self.assertEqual(out['seekStableCompositorUs'],1100000)
    def test_stale_and_unqualified_pixels_cannot_become_first_frame(self):
        trial,rows=self.fixture();rows[1]['frame']=None
        self.assertIsNone(measure(trial,rows)['firstCompositorUs'])
        rows[1]['frame']=0;rows[0]['frame']=30
        with self.assertRaises(ValueError):measure(trial,rows)
    def test_stalls_gaps_and_bad_marker_break_stable_window(self):
        for change in ('stall','gap','unknown'):
            trial,rows=self.fixture()
            if change=='stall':
                for row in rows[2:]:row['frame']=50
            if change=='gap': rows=rows[:6]+rows[10:]
            if change=='unknown':rows[7]['frame']=None
            self.assertIsNone(measure(trial,rows)['seekStableCompositorUs'])
    def test_backward_display_or_callback_before_display_is_invalid(self):
        for key,value in [('displayUs',1),('receivedUs',1)]:
            trial,rows=self.fixture();rows[4][key]=value
            with self.assertRaises(ValueError):measure(trial,rows)
    def test_wrong_seek_target_is_missing_not_zero(self):
        trial,rows=self.fixture()
        for row in rows[2:]:row['frame']=4
        self.assertIsNone(measure(trial,rows)['seekFirstCompositorUs'])
