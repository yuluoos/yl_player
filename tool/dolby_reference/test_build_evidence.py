"""Keep cross compilation and public sample inspection separate from acceptance."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


class BuildEvidenceTests(unittest.TestCase):
    def test_every_candidate_has_three_distinct_arm64_build_rows(self):
        data = json.loads((ROOT / 'build-evidence.json').read_text())
        for candidate in ['libdovi', 'libplacebo']:
            rows = [row for row in data['builds'] if row['candidate'] == candidate]
            self.assertEqual({row['platform'] for row in rows}, {'android', 'ios', 'macos'})
            self.assertEqual(len(rows), 3)
            for row in rows:
                self.assertEqual(row['architecture'], 'arm64')
                self.assertEqual(row['build_exit'], 0)
                self.assertRegex(row['artifact_sha256'], r'^[a-f0-9]{64}$')
                self.assertEqual(row['mapping_quality'], 'not_run')
                self.assertEqual(row['native_dv_signal'], 'not_run')
                if row['platform'] != 'macos':
                    self.assertEqual(row['runtime'], 'not_run')

    def test_gpu_skip_and_cpu_pass_counts_remain_separate(self):
        data = json.loads((ROOT / 'build-evidence.json').read_text())
        result = data['libplacebo_macos_tests']
        self.assertEqual((result['passed'], result['skipped'], result['failed']), (13, 1, 0))
        self.assertEqual(result['skipped_cases'], ['opengl_surfaceless.c'])
        self.assertFalse(data['production_dependency_added'])

    def test_verified_input_is_not_independent_reference(self):
        data = json.loads((ROOT / 'sample-observation.json').read_text())
        candidates = json.loads((ROOT / 'sample-candidates.json').read_text())
        self.assertTrue(data['hash_verified'])
        self.assertEqual(data['sha256'], candidates['samples'][0]['declared_lfs_sha256'])
        self.assertEqual(data['bytes'], candidates['samples'][0]['declared_bytes'])
        self.assertEqual(data['license'], 'CC-BY-4.0')
        self.assertTrue(data['attribution'])
        self.assertFalse(data['independent_target_reference'])
        self.assertIsNone(data['reference_sha256'])
        self.assertEqual(data['inspection_scope'], 'first_rpu_only')
        self.assertEqual(data['profile'], 5)
        self.assertEqual(data['cm_blocks'], ['2.9'])
        self.assertEqual(data['levels'], [1, 2, 4, 5, 6])

    def test_observation_does_not_promote_frozen_investigation(self):
        cases = json.loads((ROOT / 'cases.json').read_text())['cases']
        for row in cases:
            for result in row['platforms'].values():
                self.assertEqual(result['mapping_quality'], 'external_missing')
                self.assertEqual(result['native_dv_signal'], 'external_missing')


if __name__ == '__main__':
    unittest.main()
