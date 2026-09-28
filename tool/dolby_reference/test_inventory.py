"""The investigation ledger must never be mistaken for quality acceptance."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from inventory import validate, verify_snapshot, InventoryError

ROOT = Path(__file__).resolve().parents[2]


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((ROOT / 'tool/dolby_reference/cases.json').read_text())

    def test_complete_investigation_has_no_quality_or_signal_passes(self):
        report = validate(self.document)
        self.assertEqual(report['investigation_rows'], 24)
        self.assertEqual(report['platform_rows'], 72)
        self.assertEqual(report['mapping_quality_passes'], 0)
        self.assertEqual(report['native_dv_signal_passes'], 0)
        self.assertEqual(report['task1'], 'incomplete')

    def test_no_missing_duplicate_or_empty_combinations(self):
        for rows in [[], self.document['cases'][:-1], self.document['cases'] + [self.document['cases'][0]]]:
            value = copy.deepcopy(self.document)
            value['cases'] = rows
            with self.assertRaises(InventoryError):
                validate(value)

    def test_cannot_promote_synthetic_arithmetic_to_any_profile(self):
        for field in ['arithmetic', 'mapping_quality', 'native_dv_signal']:
            value = copy.deepcopy(self.document)
            value['cases'][0]['platforms']['macos'][field] = 'passed'
            with self.assertRaises(InventoryError):
                validate(value)

    def test_no_synthetic_or_lfs_pointer_reference_substitution(self):
        for field in ['input_sha256', 'reference_sha256', 'tolerance']:
            value = copy.deepcopy(self.document)
            value['cases'][0][field] = 'a' * 64
            with self.assertRaises(InventoryError):
                validate(value)

    def test_missing_conditions_and_unknown_metadata_cannot_disappear(self):
        for key, replacement in [('missing', []), ('levels', [1]), ('cm', 'unknown'), ('profile', '8.x')]:
            value = copy.deepcopy(self.document)
            value['cases'][0][key] = replacement
            with self.assertRaises(InventoryError):
                validate(value)

    def test_three_platforms_required(self):
        del self.document['cases'][0]['platforms']['ios']
        with self.assertRaises(InventoryError):
            validate(self.document)

    def test_snapshot_detects_modified_source(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'source.swift').write_bytes(b'original')
            rows = [{'path': 'source.swift', 'sha256': hashlib.sha256(b'original').hexdigest()}]
            verify_snapshot(root, rows)
            (root / 'source.swift').write_bytes(b'modified')
            with self.assertRaises(InventoryError):
                verify_snapshot(root, rows)

    def test_snapshot_rejects_empty_duplicate_and_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'empty').write_bytes(b'')
            import hashlib
            duplicate = {'path': 'empty', 'sha256': hashlib.sha256(b'').hexdigest()}
            for rows in [[], [duplicate, duplicate], [{'path': '../outside', 'sha256': 'a' * 64}],
                         [{'path': '/outside', 'sha256': 'a' * 64}]]:
                with self.assertRaises(InventoryError):
                    verify_snapshot(root, rows)


if __name__ == '__main__':
    unittest.main()
