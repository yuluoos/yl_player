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

    def test_fel_layer_coverage_is_recomputable_from_complete_hash_bound_trace(self):
        report = json.loads((ROOT/'fel-observation.json').read_text())
        archive = (ROOT/report['trace_file']).read_bytes()
        self.assertEqual(hashlib.sha256(archive).hexdigest(), report['trace_archive_sha256'])
        with gzip.open(ROOT/report['trace_file'], 'rb') as source:
            raw = source.read(4*1024*1024+1)
        self.assertLessEqual(len(raw), 4*1024*1024)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), report['presentation_trace_sha256'])
        rows = [json.loads(line) for line in raw.splitlines()]
        self.assertEqual(len(rows), report['rpu_count'])
        self.assertEqual(len(rows), report['declared_sample_count'])
        self.assertEqual(sorted(row['packet_index'] for row in rows), list(range(len(rows))))
        self.assertTrue(all(a['pts'] < b['pts'] for a, b in zip(rows, rows[1:])))
        self.assertTrue(all(row['profile'] == 7 for row in rows))
        layers = [row['nal_inventory'] for row in rows]
        for field in ('base_vcl_nals', 'enhancement_nals', 'enhancement_vcl_nals'):
            self.assertEqual(sum(row[field] for row in layers), report['layer_inventory'][field])
        self.assertTrue(all(row['enhancement_vcl_nals'] > 0 for row in layers))
        self.assertTrue(all(len(row['enhancement_sha256']) == 64 for row in layers))
        self.assertEqual(report['layer_inventory']['p7_packets_without_enhancement_vcl'], 0)

    def test_public_candidates_cannot_be_mistaken_for_qualified_references(self):
        fel = json.loads((ROOT/'fel-observation.json').read_text())
        public = json.loads((ROOT/'public-resources.json').read_text())
        self.assertFalse(fel['original_authoring_chain_verified'])
        self.assertFalse(fel['independent_target_reference'])
        self.assertFalse(fel['layer_inventory']['decoded_layer_pairing_verified'])
        self.assertFalse(public['qualification']['same_frame_and_grade_verified'])
        for record in (fel, public['qualification']):
            self.assertEqual(record['mapping_quality'], 'external_missing')
            self.assertEqual(record['native_dv_signal'], 'external_missing')
            self.assertIsNone(record['frozen_tolerance'])


if __name__ == '__main__':
    unittest.main()
