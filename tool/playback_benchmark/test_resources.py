import unittest
from resources import summarize_series, summarize_trials


def sample(t, cpu, phase='playing', status='ok'):
    return dict(phase=phase, monotonicUs=t, cpuUs=cpu, rssBytes=100, footprintBytes=70,
                thermal='nominal', power='ac', status=status)


def trial(samples, outcome='passed'):
    return dict(schemaVersion=1, runId='owned-resource-smoke', attempt=1, plannedAttempts=1,
                pid=123, buildMode='debug', intervalMs=250, engine='managedFallback', decoder='hardware', outcome=outcome, samples=samples)


class ResourceTests(unittest.TestCase):
    def test_multicore_percent_and_distinct_memory_ledgers(self):
        result=summarize_series(trial([sample(1000000,100),sample(2000000,1500100)]))
        p=result['phases']['playing']
        self.assertEqual(p['cpuOneCorePercent']['weightedMean'],150)
        self.assertEqual(p['rssBytes']['peak'],100)
        self.assertEqual(p['footprintBytes']['peak'],70)
        self.assertFalse(result['budgetAdmission'])

    def test_first_sample_and_singleton_are_unknown_not_zero(self):
        p=summarize_series(trial([sample(100,20)]))['phases']['playing']
        self.assertIsNone(p['cpuOneCorePercent']['weightedMean'])
        self.assertEqual(p['cpuOneCorePercent']['intervals'],0)

    def test_missing_samples_are_retained_and_break_cpu_interval(self):
        missing=sample(200,None,status='unavailable');missing.update(rssBytes=None,footprintBytes=None)
        r=summarize_series(trial([sample(100,10),missing,sample(300,50)]))
        self.assertEqual(r['unavailableSamples'],1)
        self.assertIsNone(r['phases']['playing']['cpuOneCorePercent']['weightedMean'])

    def test_phase_boundary_not_charged_to_either_cpu_window(self):
        r=summarize_series(trial([sample(100,10,'idle'),sample(200,100),sample(300,110)]))
        self.assertEqual(r['phases']['playing']['cpuOneCorePercent']['weightedMean'],10)
        self.assertIsNone(r['phases']['idle']['cpuOneCorePercent']['weightedMean'])

    def test_cpu_weighting_uses_elapsed_time_not_sample_average(self):
        r=summarize_series(trial([sample(100,0),sample(200,100),sample(500,100)]))
        self.assertEqual(r['phases']['playing']['cpuOneCorePercent']['weightedMean'],25)
        self.assertEqual(r['phases']['playing']['cpuOneCorePercent']['peak'],100)

    def test_nonmonotonic_and_counter_reset_rejected(self):
        for second in [sample(100,11),sample(99,11),sample(200,9)]:
            with self.assertRaises(ValueError): summarize_series(trial([sample(100,10),second]))

    def test_failures_and_empty_skips_are_not_successes(self):
        r=summarize_series(trial([],outcome='skipped'));self.assertEqual(r['outcome'],'skipped')
        with self.assertRaises(ValueError): summarize_series(trial([]))

    def test_unknown_thermal_power_retained_and_temperature_not_invented(self):
        s=sample(100,10);s.update(thermal='unknown',power='unknown')
        r=summarize_series(trial([s]));self.assertEqual(r['thermalCounts'],{'unknown':1})
        self.assertIsNone(r['temperatureCelsius']);self.assertEqual(r['powerCounts'],{'unknown':1})

    def test_bad_types_private_fields_invalid_phases_rejected(self):
        for key,value in [('cpuUs',True),('rssBytes',-1),('phase','secret-url'),('extra','private')]:
            s=sample(100,10);s[key]=value
            with self.assertRaises(ValueError): summarize_series(trial([s]))

    def test_same_phase_cannot_reappear_after_a_later_phase(self):
        with self.assertRaises(ValueError):
            summarize_series(trial([sample(100,1,'idle'),sample(200,2),sample(300,3,'idle')]))

class RunTests(unittest.TestCase):
    def test_failed_and_skipped_trials_remain_in_denominator(self):
        a=trial([sample(100,10)],'failed'); a['plannedAttempts']=2
        b=trial([],'skipped'); b.update(plannedAttempts=2,attempt=2)
        result=summarize_trials([a,b])
        self.assertEqual(result['outcomes'],{'failed':1,'skipped':1})
        self.assertFalse(result['performanceBaseline'])

    def test_missing_duplicate_or_other_process_trial_rejected(self):
        a=trial([sample(100,10)]); a['plannedAttempts']=2
        b=trial([sample(200,20)]); b.update(plannedAttempts=2,attempt=2)
        for values in [[a],[a,a],[a,{**b,'pid':456}]]:
            with self.assertRaises(ValueError): summarize_trials(values)

if __name__=='__main__':unittest.main()
