import unittest


class AddressHistoryTests(unittest.TestCase):
    def test_monitor_recovers_after_actual_partial_file_append(self):
        import json,tempfile,time
        from pathlib import Path
        from unittest.mock import patch
        from run_address_history import collect_history
        marker=dict(schemaVersion=1,runId='run-1',pid=123,workload='playback',attempt=1,phase='live',edge='begin',monotonicUs=100)
        line='flutter: YL_RESOURCE_CHECKPOINT='+json.dumps(marker)+'\n'
        with tempfile.TemporaryDirectory() as tmp:
            def partial_run(path,*args,**kwargs):
                path.mkdir();(path/'defines.json').write_text(json.dumps({'YL_RESOURCE_RUN_ID':'run-1'}))
                log=path/'playback.log';log.write_text(line[:40]);time.sleep(.35)
                with log.open('a') as stream:stream.write(line[40:])
                time.sleep(.35)
                return False
            with patch('run_address_history.collect',side_effect=partial_run),patch('run_address_history.capture_probe',return_value={'status':'unavailable'}) as probe:
                self.assertFalse(collect_history(Path(tmp)/'new','unused'))
                self.assertEqual(probe.call_count,2,'Partial append killed monitor before completed marker')

    def test_marker_append_fragment_waits_for_newline_without_losing_prior_markers(self):
        import json
        from run_address_history import checkpoint_markers
        marker=dict(schemaVersion=1,runId='run-1',pid=123,workload='playback',attempt=1,phase='live',edge='begin',monotonicUs=100)
        first='flutter: YL_RESOURCE_CHECKPOINT='+json.dumps(marker)+'\n'
        last='flutter: YL_RESOURCE_CHECKPOINT='+json.dumps(dict(marker,edge='end',monotonicUs=200))
        self.assertEqual(list(checkpoint_markers(first+last[:40])),[marker])
        self.assertEqual(len(list(checkpoint_markers(first+last+'\n'))),2)
        with self.assertRaises(ValueError):list(checkpoint_markers('flutter: YL_RESOURCE_CHECKPOINT=broken\n'))

    def test_target_is_bounded_deterministic_and_not_chosen_from_dirty_growth(self):
        from run_address_history import select_target
        def region(start,size,protection='rw-/rwx'):
            return dict(start=hex(start),endExclusive=hex(start+size),virtualBytes=size,protection=protection)
        a=region(0x100000,20*1024*1024);b=region(0x9000000,20*1024*1024)
        self.assertEqual(select_target([b,a,region(0x4000000,30*1024*1024,'r-x/rwx')]),a)
        self.assertIsNone(select_target([region(0x100000,1024)]))

    def test_failed_run_retains_unobserved_queries_and_frozen_protocol(self):
        import json,tempfile
        from pathlib import Path
        from unittest.mock import patch
        from run_address_history import collect_history
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new'
            def fail_run(path,*args,**kwargs):path.mkdir();return False
            with patch('run_address_history.collect',side_effect=fail_run),patch('run_address_history.capture_probe') as probe:
                self.assertFalse(collect_history(output,'unused'))
                probe.assert_not_called()
            result=json.loads((output/'history-probes.json').read_text())
            self.assertEqual(len(result['records']),15)
            self.assertTrue(all(r['status']=='not_observed' for r in result['records']))
            self.assertIsNone(result['target'])
            self.assertEqual(json.loads((output/'protocol.json').read_text())['windows'],[[1,'live'],[2,'disposed'],[8,'disposed']])
            with self.assertRaises(FileExistsError):collect_history(output,'unused')

if __name__=='__main__':unittest.main()
