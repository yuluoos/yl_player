"""The real input observation remains separate from mapping/signal acceptance."""
import gzip
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).parent


class StreamEvidenceTests(unittest.TestCase):
    def test_complete_trace_is_hash_bound_and_presentation_ordered(self):
        report = json.loads((ROOT/'stream-observation.json').read_text())
        original = json.loads((ROOT/'sample-observation.json').read_text())
        self.assertEqual(report['media_sha256'], original['sha256'])
        self.assertEqual(report['first_packet_rpu_sha256'], original['first_rpu_sha256'])
        archive = ROOT/report['trace_file']
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), report['trace_archive_sha256'])
        with gzip.open(archive,'rb') as source:
            raw = source.read(4*1024*1024+1)
        self.assertLessEqual(len(raw), 4*1024*1024)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), report['presentation_trace_sha256'])
        rows = [json.loads(line) for line in raw.splitlines()]
        self.assertEqual(len(rows), report['packet_count'])
        self.assertEqual(len(rows), report['rpu_count'])
        self.assertEqual(len(rows), report['declared_sample_count'])
        self.assertEqual(report['container_coverage'], 'finite_box_extents_and_declared_samples')
        self.assertEqual(sorted(row['packet_index'] for row in rows), list(range(len(rows))))
        self.assertTrue(all(a['pts'] < b['pts'] for a,b in zip(rows,rows[1:])))
        self.assertEqual([rows[0]['pts'],rows[-1]['pts']],report['pts_range'])
        self.assertEqual(sum(a['display_metadata_sha256'] != b['display_metadata_sha256']
                             for a,b in zip(rows,rows[1:])),report['display_metadata_transitions'])

    def test_full_input_inspection_does_not_promote_mapping_or_signal(self):
        report = json.loads((ROOT/'stream-observation.json').read_text())
        self.assertEqual(report['mapping_quality'],'external_missing')
        self.assertEqual(report['native_dv_signal'],'external_missing')
        self.assertFalse(report['independent_target_reference'])
        self.assertFalse(report['effective_metadata_resolved'])
        self.assertFalse(report['decoded_frame_alignment_verified'])
        self.assertIsNone(report['reference_sha256'])
        self.assertIsNone(report['frozen_tolerance'])


if __name__ == '__main__':
    unittest.main()
