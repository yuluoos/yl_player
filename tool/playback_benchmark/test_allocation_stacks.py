import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class AllocationStackTests(unittest.TestCase):
    def test_timeout_preserves_partial_tree_and_cannot_qualify(self):
        from run_allocation_stacks import capture_tree
        def timeout(command,**kwargs):
            kwargs['stdout'].write('partial allocation tree\n');kwargs['stdout'].flush()
            raise subprocess.TimeoutExpired(command,8)
        marker=dict(attempt=2,phase='disposed',runId='run-1',pid=123)
        with tempfile.TemporaryDirectory() as tmp:
            with patch('run_allocation_stacks.subprocess.check_output',return_value=__import__('run_allocation_stacks').EXECUTABLE.as_posix()),patch('run_allocation_stacks.subprocess.run',side_effect=timeout):
                r=capture_tree(marker,Path(tmp))
            self.assertNotEqual(r['status'],'captured');self.assertFalse(r['qualified'])
            self.assertEqual((Path(tmp)/r['raw']['file']).read_text(),'partial allocation tree\n')
            self.assertIn('-noContent',r['command']);self.assertEqual(r['command'][-1],'.*')

    def test_empty_call_graph_is_not_usable_attribution(self):
        from run_allocation_stacks import capture_tree
        # Actual observed shape: header and image list, but no call graph rows.
        empty = "malloc_history Report Version:  2.0\nProcess:         yl_player_example [123]\nCall graph:\n\nTotal number in stack -- format footer\n\nBinary Images:\n"
        def emit(command, **kwargs):
            kwargs['stdout'].write(empty)
            return subprocess.CompletedProcess(command, 0)
        with tempfile.TemporaryDirectory() as tmp:
            with patch('run_allocation_stacks.subprocess.check_output',return_value=__import__('run_allocation_stacks').EXECUTABLE.as_posix()),patch('run_allocation_stacks.subprocess.run',side_effect=emit):
                r=capture_tree(dict(attempt=1,phase='live',runId='run-1',pid=123),Path(tmp))
            self.assertNotEqual(r['status'],'captured')
            self.assertEqual((Path(tmp)/r['raw']['file']).read_text(),empty)

    def test_wrong_process_cannot_be_inspected(self):
        from run_allocation_stacks import capture_tree
        with tempfile.TemporaryDirectory() as tmp:
            with patch('run_allocation_stacks.subprocess.check_output',return_value='/unrelated/process'),patch('run_allocation_stacks.subprocess.run') as run:
                r=capture_tree(dict(attempt=1,phase='live',runId='run-1',pid=123),Path(tmp))
            run.assert_not_called();self.assertNotEqual(r['status'],'captured')

    def test_failed_workload_keeps_nine_planned_observers_and_frozen_selection(self):
        from run_allocation_stacks import collect_stacks
        def fail(path,*args,**kwargs):
            self.assertTrue(kwargs['allocation_stacks']);self.assertTrue(kwargs['lifetime_probes'])
            path.mkdir();return False
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'new'
            with patch('run_allocation_stacks.collect',side_effect=fail):
                self.assertFalse(collect_stacks(out,'unused'))
            p=json.loads((out/'protocol.json').read_text());r=json.loads((out/'allocation-probes.json').read_text())
            self.assertEqual(p['classSelection'],'.*');self.assertEqual(p['plannedAttempts'],10)
            self.assertEqual(len(r['records']),9);self.assertTrue(all(x['status']=='not_observed' for x in r['records']))
            self.assertFalse(r['complete'])
            with self.assertRaises(FileExistsError):collect_stacks(out,'unused')

    def test_resource_stack_mode_rejects_incompatible_workloads(self):
        from run_resources import collect
        with tempfile.TemporaryDirectory() as tmp:
            for options in ({},dict(profile_cycles=True),dict(profile_cycles=True,lifetime_probes=True,harness_only=True)):
                with self.assertRaises(ValueError):collect(Path(tmp)/'bad','unused',allocation_stacks=True,**options)

if __name__=='__main__':unittest.main()
