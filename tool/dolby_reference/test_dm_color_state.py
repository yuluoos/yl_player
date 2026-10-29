"""Synthetic state-machine cases are not Dolby mapping/physical evidence."""
import copy
import io
import json
import unittest

from dm_color_state import COLOR_RANGES, HEADER_RANGES, HEADER_FLAGS, resolve
from stream_inventory import InspectionError, summarize


def value(identifier=0, *, compressed=False, marker=100):
    color = {key: 0 if compressed else lo for key, (lo, hi) in COLOR_RANGES.items()}
    if not compressed:
        color.update(signal_eotf=65535, ycc_to_rgb_coef0=marker)
    return {
        'profile': 8, 'el_type': None, 'cm_levels': {},
        'display_metadata': dict(color, compressed=compressed,
            affected_dm_metadata_id=identifier, current_dm_metadata_id=identifier,
            scene_refresh_flag=0),
        'use_previous_mapping': False, 'unparsed_rpu_bits': 0,
        'mapping': {'vdr_rpu_id': 0}, 'previous_mapping_id': None,
        'rpu_header': {
            **{key: lo for key, (lo, hi) in HEADER_RANGES.items()},
            **{key: False for key in HEADER_FLAGS},
            'rpu_type': 2, 'rpu_format': 18, 'vdr_rpu_profile': 1,
            'vdr_seq_info_present_flag': True, 'vdr_dm_metadata_present_flag': True,
            'reserved_zero_3bits': int(compressed), 'use_prev_vdr_rpu_flag': False,
            'prev_vdr_rpu_id': 0, 'bl_bit_depth_minus8': 2,
        },
    }


class DmColorStateTests(unittest.TestCase):
    def test_compressed_zero_placeholders_inherit_latest_complete_color(self):
        values = [value(marker=123), value(compressed=True), value(marker=456), value(compressed=True)]
        saved = copy.deepcopy(values)
        state = resolve(values)
        self.assertEqual([r['color_source_packet_index'] for r in state], [0, 0, 2, 2])
        self.assertEqual([r['color']['ycc_to_rgb_coef0'] for r in state], [123, 123, 456, 456])
        self.assertEqual(state[0]['color_sha256'], state[1]['color_sha256'])
        self.assertNotEqual(state[0]['color_sha256'], state[2]['color_sha256'])
        self.assertEqual(values, saved)
        state[0]['color']['ycc_to_rgb_coef0'] = 999
        self.assertEqual(state[1]['color']['ycc_to_rgb_coef0'], 123)

    def test_decode_order_precedes_presentation_and_mapping_is_independent(self):
        values = [value(marker=123), value(compressed=True)]
        values[1].update(mapping=None, previous_mapping_id=0, use_previous_mapping=True)
        values[1]['rpu_header']['use_prev_vdr_rpu_flag'] = True
        rows = [dict(packet_index=0, pts=2, dts=0, rpu_sha256='a'*64),
                dict(packet_index=1, pts=1, dts=1, rpu_sha256='b'*64)]
        trace = io.BytesIO()
        result = summarize(rows, values, time_base='1/24', media_sha256='f'*64,
                           trace_sink=trace, include_dm_color=True)
        records = [json.loads(line) for line in trace.getvalue().splitlines()]
        self.assertEqual(result['schema_version'], 4)
        self.assertTrue(result['dm_color_state_resolved'])
        self.assertFalse(result['effective_metadata_resolved'])
        self.assertEqual(result['compressed_dm_color_rpus'], 1)
        self.assertEqual(records[0]['packet_index'], 1)
        self.assertEqual(records[0]['dm_color_state']['color_source_packet_index'], 0)
        self.assertEqual(records[0]['mapping_reference']['mapping_source_packet_index'], 0)

    def test_refresh_is_per_packet_and_does_not_erase_static_color(self):
        values = [value(), value(compressed=True)]
        values[1]['display_metadata']['scene_refresh_flag'] = 1
        state = resolve(values)
        self.assertEqual([r['scene_refresh_flag'] for r in state], [0, 1])
        self.assertEqual(state[0]['color_sha256'], state[1]['color_sha256'])

    def test_new_epoch_or_switched_id_cannot_resurrect_history(self):
        for values in [[value(compressed=True)],
                       [value(), value(1, compressed=True)],
                       [value(), value(1), value(0, compressed=True)]]:
            with self.subTest(values=values), self.assertRaises(InspectionError):
                resolve(values)
        self.assertEqual(resolve([value(0), value(1), value(1, compressed=True)])[2]['color_source_packet_index'], 1)

    def test_ambiguous_headers_ids_and_unknown_payload_fail_closed(self):
        mutations = [
            lambda v: v['display_metadata'].update(current_dm_metadata_id=1),
            lambda v: v['display_metadata'].update(affected_dm_metadata_id=True),
            lambda v: v['display_metadata'].update(current_dm_metadata_id=16),
            lambda v: v['display_metadata'].update(scene_refresh_flag=True),
            lambda v: v.update(display_metadata=None),
            lambda v: v.update(unparsed_rpu_bits=1),
            lambda v: v['rpu_header'].update(reserved_zero_3bits=2),
            lambda v: v['rpu_header'].update(vdr_seq_info_present_flag=False),
            lambda v: v['rpu_header'].update(vdr_dm_metadata_present_flag=False),
            lambda v: v['rpu_header'].update(rpu_format=0x700),
            lambda v: v['rpu_header'].update(use_prev_vdr_rpu_flag=True),
            lambda v: v['display_metadata'].update(compressed=True),
            lambda v: v['display_metadata'].update(unrecognized=123),
        ]
        for mutation in mutations:
            bad = value(); mutation(bad)
            with self.subTest(mutation=mutation), self.assertRaises(InspectionError): resolve([bad])

    def test_color_types_ranges_missing_fields_and_compressed_garbage_rejected(self):
        for key, (lo, hi) in COLOR_RANGES.items():
            for invalid in [lo-1, hi+1, True, 1.0, '0', None]:
                bad = value(); bad['display_metadata'][key] = invalid
                with self.subTest(key=key, invalid=invalid), self.assertRaises(InspectionError): resolve([bad])
            bad = value(); del bad['display_metadata'][key]
            with self.assertRaises(InspectionError): resolve([bad])
        bad = value(compressed=True); bad['display_metadata']['ycc_to_rgb_coef0'] = 1
        with self.assertRaises(InspectionError): resolve([value(), bad])

    def test_compressed_config_change_and_unbounded_inputs_rejected(self):
        for key, val in [('bl_bit_depth_minus8', 4), ('vdr_rpu_profile', 0)]:
            bad = value(compressed=True); bad['rpu_header'][key] = val
            with self.assertRaises(InspectionError): resolve([value(), bad])
        for values in [[], None, [value()] * 32769]:
            with self.assertRaises(InspectionError): resolve(values)


if __name__ == '__main__': unittest.main()
