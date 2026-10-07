import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import run_lifetime_probes as runner


class LongLifetimeTests(unittest.TestCase):
    def test_failed_run_retains_all_eight_unobserved_probes(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new'
            def failed(path,*args,**kwargs):
                path.mkdir();return False
            with patch.object(runner,'collect',side_effect=failed):
                self.assertFalse(runner.collect_lifetimes(output,'unused',long_cycles=True))
            r=json.loads((output/'lifetime-probes.json').read_text())
            self.assertEqual(len(r['records']),8)
            self.assertEqual({x['attempt'] for x in r['records']},{1,10,50,100})
            self.assertEqual({x['tool'] for x in r['records']},{'heap','vmmap'})
            self.assertTrue(all(x['status']=='not_observed' and not x['qualified'] for x in r['records']))

    def test_long_runner_rejects_legacy_markers_even_for_same_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new'
            def legacy(path,*args,**kwargs):
                path.mkdir()
                (path/'defines.json').write_text(json.dumps({'YL_RESOURCE_RUN_ID':'run-1'}))
                marker=dict(schemaVersion=1,runId='run-1',pid=123,workload='playback',attempt=1,phase='live',edge='begin',monotonicUs=100)
                (path/'playback.log').write_text('YL_RESOURCE_CHECKPOINT='+json.dumps(marker)+'\n')
                return False
            with patch.object(runner,'collect',side_effect=legacy),patch.object(runner.subprocess,'run') as inspect:
                self.assertFalse(runner.collect_lifetimes(output,'unused',long_cycles=True))
                inspect.assert_not_called()
            r=json.loads((output/'lifetime-probes.json').read_text())
            self.assertIn('ValueError',r['errors'])

    def test_foreign_executable_is_not_inspected(self):
        self.assertTrue(hasattr(runner,'capture_probe'),'Missing independently bounded probe capture')
        with tempfile.TemporaryDirectory() as tmp:
            marker=dict(runId='run-1',pid=123,attempt=50,phase='disposed')
            with patch.object(runner.subprocess,'check_output',return_value='/foreign/app'),patch.object(runner.subprocess,'run') as inspect:
                r=runner.capture_probe(marker,'vmmap',Path(tmp))
                inspect.assert_not_called()
            self.assertEqual(r['status'],'unavailable')
            self.assertEqual(r['errorType'],'ValueError')
            self.assertGreaterEqual(r['endedUs'],r['startedUs'])

if __name__=='__main__':unittest.main()
