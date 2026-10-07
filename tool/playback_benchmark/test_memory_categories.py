import unittest
from memory_categories import parse_vmmap, probe_identity

HEADER='''Process:         yl_player_example [123]
Report Version:  7
Physical footprint:         60.2M
                                VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION
REGION TYPE                        SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced)
===========                     ======= ========    =====  ======= ========   ======    =====  =======
'''
ROW='Malloc Large (empty) 7920K 7904K 7904K 0K 0K 0K 0K 1         see MALLOC ZONE table below\n'
END='=========== ======= ======== ===== ======= ======== ====== ===== =======\nTOTAL 60.2M\n'

class MemoryCategoryTests(unittest.TestCase):
    def test_preserves_rounded_units_and_distinct_ledgers(self):
        r=parse_vmmap(HEADER+ROW+END,123)
        self.assertEqual(r['physicalFootprint'],'60.2M')
        self.assertEqual(r['regions']['Malloc Large (empty)']['residentSize'],'7904K')
        self.assertEqual(r['regions']['Malloc Large (empty)']['regionCount'],1)
        self.assertFalse(r['exactBytes'])
        self.assertIsNone(r['leakVerdict'])

    def test_absent_category_is_not_synthesized_as_zero(self):
        r=parse_vmmap(HEADER+'__CTF 824 824 0K 0K 0K 0K 0K 1\n'+END,123)
        self.assertNotIn('Malloc Large (empty)',r['regions'])
        self.assertEqual(r['regions']['__CTF']['virtualSize'],'824')

    def test_wrong_process_or_version_or_columns_rejected(self):
        for s in (HEADER.replace('[123]','[124]'),HEADER.replace('Version:  7','Version:  8'),HEADER.replace('DIRTY  SWAPPED','SWAPPED  DIRTY')):
            with self.assertRaises(ValueError):parse_vmmap(s+ROW+END,123)

    def test_truncated_duplicate_or_invalid_row_rejected(self):
        for s in (HEADER+ROW,HEADER+ROW+ROW+END,HEADER+ROW.replace('7904K','unknown',1)+END,HEADER+END,HEADER+ROW.replace('1         see','-1         see')+END):
            with self.assertRaises(ValueError):parse_vmmap(s,123)

    def test_large_or_error_output_never_becomes_empty_success(self):
        for s in ('vmmap: cannot inspect task','x'*2097153):
            with self.assertRaises(ValueError):parse_vmmap(s,123)

    def test_probe_identity_cannot_select_unrelated_or_nonprofile_process(self):
        row=dict(runId='run-1',schemaVersion=2,buildMode='profile',plannedAttempts=10,workload='harness-only',attempt=2,pid=123)
        self.assertEqual(probe_identity(row,'run-1','harness-only'),(2,123))
        for changes in ({'pid':True},{'pid':-1},{'attempt':11},{'attempt':True},{'runId':'other'},{'workload':'playback'},{'buildMode':'debug'},{'schemaVersion':1},{'plannedAttempts':3}):
            with self.assertRaises(ValueError):probe_identity(dict(row,**changes),'run-1','harness-only')

if __name__=='__main__':unittest.main()

class CategoryRunnerTests(unittest.TestCase):
    def test_failed_run_retains_all_unobserved_probes(self):
        import json
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from run_memory_categories import collect_categories
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'new'
            def fail_run(path,*args,**kwargs):
                path.mkdir()
                return False
            with patch('run_memory_categories.collect',side_effect=fail_run),patch('run_memory_categories.subprocess.run') as inspect:
                self.assertFalse(collect_categories(output,'unused',harness_only=True))
                inspect.assert_not_called()
            r=json.loads((output/'category-probes.json').read_text())
            self.assertEqual([x['attempt'] for x in r['records']],[2,5,8])
            self.assertEqual([x['status'] for x in r['records']],['not_observed']*3)
            self.assertFalse(r['complete'])

    def test_existing_evidence_is_never_reused(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from run_memory_categories import collect_categories
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary);(output/'category-probes.json').write_text('keep')
            with patch('run_memory_categories.collect') as collect:
                with self.assertRaises(FileExistsError):collect_categories(output,'unused',harness_only=True)
                collect.assert_not_called()
            self.assertEqual((output/'category-probes.json').read_text(),'keep')
