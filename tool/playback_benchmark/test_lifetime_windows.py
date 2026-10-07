import unittest
from lifetime_windows import validate_window


def mark(edge,time):
    return dict(schemaVersion=1,runId='run-1',pid=123,workload='playback',attempt=2,phase='disposed',edge=edge,monotonicUs=time)


def probe(**changes):
    return dict(dict(runId='run-1',pid=123,attempt=2,phase='disposed',status='captured',startedUs=110,endedUs=190),**changes)


class LifetimeWindowTests(unittest.TestCase):
    def test_only_complete_same_clock_bracket_is_qualified(self):
        self.assertTrue(validate_window(mark('begin',100),mark('end',200),probe()))
        self.assertFalse(validate_window(None,mark('end',200),probe()))
        self.assertFalse(validate_window(mark('begin',100),None,probe()))

    def test_outside_or_failed_capture_is_not_disposal_evidence(self):
        for change in ({'startedUs':99},{'endedUs':201},{'status':'failed'},{'status':'unavailable'}):
            self.assertFalse(validate_window(mark('begin',100),mark('end',200),probe(**change)))

    def test_mixed_player_trial_phase_or_run_rejected(self):
        for change in ({'pid':124},{'runId':'other'},{'attempt':8},{'phase':'live'}):
            with self.assertRaises(ValueError):validate_window(mark('begin',100),mark('end',200),probe(**change))

    def test_bad_clock_types_reversal_or_edges_rejected(self):
        for p in (probe(startedUs=True),probe(startedUs=195,endedUs=190),probe(endedUs=-1)):
            with self.assertRaises(ValueError):validate_window(mark('begin',100),mark('end',200),p)
        with self.assertRaises(ValueError):validate_window(mark('end',100),mark('end',200),probe())
        with self.assertRaises(ValueError):validate_window(mark('begin',200),mark('end',100),probe())

    def test_only_declared_playback_windows_are_supported(self):
        for change in ({'workload':'harness-only'},{'schemaVersion':True},{'attempt':3},{'extra':'private'}):
            with self.assertRaises(ValueError):validate_window(dict(mark('begin',100),**change),mark('end',200),probe())
        a=dict(mark('begin',100),phase='live',attempt=1);b=dict(a,edge='end',monotonicUs=200)
        self.assertTrue(validate_window(a,b,probe(phase='live',attempt=1)))

if __name__=='__main__':unittest.main()
