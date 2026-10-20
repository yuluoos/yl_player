"""Synthetic NAL coverage tests are not FEL reconstruction evidence."""
import hashlib
import io
import json
import test_stream_inventory as helpers
import unittest

from stream_inventory import InspectionError, extract_rpus, summarize
from test_stream_inventory import nal, packet, parsed


class LayerInventoryTests(unittest.TestCase):
    def extract(self, data):
        return extract_rpus(io.BytesIO(data), [packet(data)], length_size=4,
                            stream_index=0, media_size=len(data), include_layers=True)

    def test_enhancement_wrappers_are_counted_and_hashed_without_rewriting(self):
        # Two BL slices, one EL parameter set, two EL slices, original RPU.
        enhancement = [nal(63, b'\x40\x01vps'),
                       nal(63, b'\x26\x01first'), nal(63, b'\x02\x01second')]
        data = nal(19) + nal(1) + b''.join(enhancement) + nal(62)
        rows, rpus = self.extract(data)
        self.assertEqual(rows[0]['nal_inventory'], {
            'base_vcl_nals': 2, 'enhancement_vcl_nals': 2,
            'enhancement_nals': 3,
            'enhancement_sha256': hashlib.sha256(b''.join(enhancement)).hexdigest()})
        self.assertEqual(rpus, nal(62))

    def test_parameter_sets_do_not_count_as_enhancement_pictures(self):
        rows, _ = self.extract(nal(19) + nal(63, b'\x40\x01vps') + nal(62))
        self.assertEqual(rows[0]['nal_inventory']['enhancement_vcl_nals'], 0)
        self.assertEqual(rows[0]['nal_inventory']['enhancement_nals'], 1)

    def test_absent_enhancement_is_explicit_and_does_not_hash_empty_bytes(self):
        rows, _ = self.extract(nal(19) + nal(62))
        self.assertEqual(rows[0]['nal_inventory']['enhancement_nals'], 0)
        self.assertIsNone(rows[0]['nal_inventory']['enhancement_sha256'])

    def test_invalid_nested_or_nonzero_layer_headers_refuse_complete_inventory(self):
        for inner in [b'', b'\x26', b'\xa6\x01bad', b'\x26\x00bad',
                      b'\x26\x09other-layer', b'\x7e\x01nested', b'\x7c\x01rpu']:
            with self.subTest(inner=inner), self.assertRaises(InspectionError):
                self.extract(nal(19) + nal(63, inner) + nal(62))
        raw = b'\x26\x09other-layer'
        with self.assertRaises(InspectionError):
            self.extract(len(raw).to_bytes(4, 'big') + raw + nal(62))

    def test_header_only_base_and_enhancement_vcl_are_rejected(self):
        for data in [nal(19, b'') + nal(62),
                     nal(19) + nal(63, b'\x26\x01') + nal(62)]:
            with self.subTest(data=data), self.assertRaises(InspectionError):
                self.extract(data)

    def test_hash_framing_is_canonical_independent_of_mp4_length_size(self):
        nals = [b'\x26\x01picture', b'\x7e\x01\x26\x01EL', b'\x7c\x01rpu']
        hashes = []
        for length_size in (1, 2, 3, 4):
            data = b''.join(len(n).to_bytes(length_size, 'big') + n for n in nals)
            rows, _ = extract_rpus(io.BytesIO(data), [packet(data)], length_size=length_size,
                                  stream_index=0, media_size=len(data), include_layers=True)
            hashes.append(rows[0]['nal_inventory']['enhancement_sha256'])
        self.assertEqual(len(set(hashes)), 1)
        self.assertEqual(hashes[0], hashlib.sha256(nal(63, b'\x26\x01EL')).hexdigest())

    def test_summary_exposes_missing_p7_layers_without_claiming_pairing(self):
        rows, _ = self.extract(nal(19) + nal(62))
        value = parsed(); value['profile'] = 7; value['el_type'] = 'FEL'
        result = summarize(rows, [value], time_base='1/24', media_sha256='c'*64,
                           include_layers=True)
        self.assertEqual(result['schema_version'], 2)
        self.assertEqual(result['layer_inventory']['p7_packets_without_enhancement_vcl'], 1)
        self.assertEqual(result['layer_inventory']['packets_with_enhancement_vcl'], 0)
        self.assertFalse(result['layer_inventory']['decoded_layer_pairing_verified'])
        self.assertEqual(result['mapping_quality'], 'external_missing')
        self.assertEqual(result['native_dv_signal'], 'external_missing')

    def test_legacy_collection_does_not_change_trace_or_schema(self):
        data = nal(19) + nal(62)
        rows, _ = extract_rpus(io.BytesIO(data), [packet(data)], length_size=4,
                              stream_index=0, media_size=len(data))
        self.assertNotIn('nal_inventory', rows[0])
        result = summarize(rows, [parsed()], time_base='1/24', media_sha256='c'*64)
        self.assertEqual(result['schema_version'], 1)
        self.assertNotIn('layer_inventory', result)


class LayerCliTests(unittest.TestCase):
    setUp = helpers.CollectorCliTests.setUp
    script = helpers.CollectorCliTests.script
    cli = helpers.CollectorCliTests.cli

    def test_opt_in_reaches_cli_summary_and_hash_bound_trace(self):
        trace = self.root/'trace.jsonl'
        result = self.cli('--layers', '--trace', trace)
        self.assertEqual(result.returncode, 0, result.stdout)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['schema_version'], 2)
        self.assertEqual(summary['layer_inventory']['base_vcl_nals'], 1)
        self.assertEqual(summary['layer_inventory']['enhancement_nals'], 0)
        self.assertEqual(summary['presentation_trace_sha256'],
                         hashlib.sha256(trace.read_bytes()).hexdigest())
        self.assertIsNone(json.loads(trace.read_text())['nal_inventory']['enhancement_sha256'])

    def test_bad_enhancement_header_has_safe_failure_and_no_partial_trace(self):
        self.data = nal(19) + nal(63, b'X') + nal(62)
        self.container = helpers.box(b'ftyp', b'isom') + helpers.box(b'moov') + helpers.box(b'mdat', self.data)
        self.media.write_bytes(self.container)
        self.sha = hashlib.sha256(self.container).hexdigest()
        self.probe_data['packets'] = [packet(self.data, pos=len(self.container)-len(self.data))]
        self.probe = self.script('probe', 'print('+repr(json.dumps(self.probe_data))+')')
        trace = self.root/'trace.jsonl'
        result = self.cli('--layers', '--trace', trace)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['code'], 'dolby.stream_inspection_failed')
        self.assertNotIn('PRIVATE', result.stdout + result.stderr)
        self.assertFalse(trace.exists())

    def test_header_only_enhancement_cannot_publish_a_trace(self):
        self.data = nal(19) + nal(63, b'\x26\x01') + nal(62)
        self.container = helpers.box(b'ftyp', b'isom') + helpers.box(b'moov') + helpers.box(b'mdat', self.data)
        self.media.write_bytes(self.container)
        self.sha = hashlib.sha256(self.container).hexdigest()
        self.probe_data['packets'] = [packet(self.data, pos=len(self.container)-len(self.data))]
        self.probe = self.script('probe', 'print('+repr(json.dumps(self.probe_data))+')')
        trace = self.root/'header-only.jsonl'
        result = self.cli('--layers', '--trace', trace)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(trace.exists())
