"""Synthetic CM state tests do not qualify trim execution or real compressed video."""
import copy
import io
import json
import unittest
from dm_block_state import resolve
from test_dm_color_state import value
from stream_inventory import InspectionError, summarize


def l1(avg=1000): return {'Level1': {'min_pq':0,'max_pq':3079,'avg_pq':avg}}
def l6(nits=1000): return {'Level6': {'max_display_mastering_luminance':nits,
    'min_display_mastering_luminance':1,'max_content_light_level':nits,'max_frame_average_light_level':200}}
def l2(target=2000): return {'Level2':dict(target_max_pq=target,trim_slope=2048,trim_offset=2048,
    trim_power=2048,trim_chroma_weight=2048,trim_saturation_gain=2048,ms_weight=-1)}
def l254(): return {'Level254':dict(dm_mode=0,dm_version_index=2)}
def record(v29=(), v40=(), **kwargs):
    v=value(**kwargs)
    for cm,key,blocks in [('2.9','cmv29_metadata',v29),('4.0','cmv40_metadata',v40)]:
        if blocks:
            v['display_metadata'][key]={'num_ext_blocks':len(blocks),'ext_metadata_blocks':list(blocks)}
            v['cm_levels'][cm]=sorted({int(next(iter(b))[5:]) for b in blocks})
    return v


class DmBlockStateTests(unittest.TestCase):
    def test_only_static_blocks_inherit_and_dynamic_trims_expire(self):
        values=[record([l6(),l1(),l2()], [l254(),{'Level9':dict(length=1,source_primary_index=0)}]),
                record([l1(1200)],compressed=True)]
        saved=copy.deepcopy(values);r=resolve(values)
        self.assertEqual([(b['cm'],b['level'],b['source_packet_index']) for b in r[1]['blocks']],
                         [('2.9',1,1),('2.9',6,0),('4.0',254,0)])
        self.assertEqual(r[1]['inherited_static_blocks'],2)
        self.assertEqual(values,saved)
        next(b for b in r[0]['blocks'] if b['level']==6)['payload']['max_content_light_level']=999
        self.assertEqual(r[1]['blocks'][1]['payload']['max_content_light_level'],1000)

    def test_full_record_resets_all_previous_blocks_and_hash_is_content_based(self):
        r=resolve([record([l6()]),record([l6()]),record([l1()]),record(compressed=True)])
        self.assertEqual(r[0]['blocks_sha256'],r[1]['blocks_sha256'])
        self.assertEqual(r[1]['blocks'][0]['source_packet_index'],1)
        self.assertEqual(r[3]['blocks'],[])

    def test_targets_are_distinct_and_duplicate_targets_fail(self):
        r=resolve([record([l2(2000),l2(3000),l6()])])[0]
        self.assertEqual([b['target'] for b in r['blocks'][:2]],[2000,3000])
        for blocks in [[l2(),l2()],[l1(),l1()], [l6(),l6()]]:
            with self.assertRaises(InspectionError): resolve([record(blocks)])

    def test_compressed_static_blocks_and_unknown_levels_fail(self):
        for bad in [record([l6()],compressed=True),record(v40=[l254()],compressed=True),
                    record([{'Level32':{'opaque':0}}]),record(v40=[{'Level253':{'opaque':0}}])]:
            with self.assertRaises(InspectionError):resolve([record([l6()]),bad])

    def test_layout_counts_cm_and_types_cannot_silently_drift(self):
        mutations=[lambda v:v['display_metadata']['cmv29_metadata'].update(num_ext_blocks=2),
                   lambda v:v['display_metadata']['cmv29_metadata'].update(num_ext_blocks=True),
                   lambda v:v['cm_levels'].update({'2.9':[6]}),
                   lambda v:v['cm_levels'].update({'2.9':[True]}),
                   lambda v:v['display_metadata']['cmv29_metadata']['ext_metadata_blocks'][0]['Level1'].update(avg_pq=True),
                   lambda v:v['display_metadata']['cmv29_metadata']['ext_metadata_blocks'][0]['Level1'].update(avg_pq=4096),
                   lambda v:v['display_metadata']['cmv29_metadata']['ext_metadata_blocks'][0]['Level1'].update(unknown=1)]
        for mutation in mutations:
            v=record([l1()]);mutation(v)
            with self.assertRaises(InspectionError):resolve([v])
        with self.assertRaises(InspectionError):resolve([record([l2(i) for i in range(9)])])

    def test_all_static_levels_and_variable_length_payloads(self):
        from dm_block_state import payload_schema
        payloads = []
        for level, lengths in [(8, [10, 12, 13, 19, 25]), (9, [1, 17]), (10, [5, 21])]:
            for length in lengths:
                payload = {'length': length}
                for key, bounds in payload_schema(level, payload).items():
                    payload.setdefault(key, bounds[0])
                v=record(v40=[l254(),{f'Level{level}':payload}])
                resolve([v])
                bad=copy.deepcopy(v)
                bad['display_metadata']['cmv40_metadata']['ext_metadata_blocks'][1][f'Level{level}']['extra']=0
                with self.assertRaises(InspectionError):resolve([bad])
                payloads.append((level,payload))
        static10=next(payload for level,payload in payloads if level==10)
        static255={'Level255':dict(dm_run_mode=0,dm_run_version=0,dm_debug0=0,dm_debug1=0,dm_debug2=0,dm_debug3=0)}
        result=resolve([record([l6(),static255], [l254(),{'Level10':static10}]),record([l1()],compressed=True)])
        self.assertEqual([b['level'] for b in result[1]['blocks']],[1,6,255,10,254])
        self.assertEqual(result[1]['inherited_static_blocks'],4)

    def test_absent_history_or_wrong_id_is_rejected_by_color_contract(self):
        for values in [[record(compressed=True)], [record([l6()]),record(identifier=1,compressed=True)]]:
            with self.assertRaises(InspectionError):resolve(values)

    def test_schema_five_reorders_only_after_source_resolution(self):
        rows=[dict(packet_index=0,pts=2,dts=0,rpu_sha256='a'*64),dict(packet_index=1,pts=1,dts=1,rpu_sha256='b'*64)]
        trace=io.BytesIO();result=summarize(rows,[record([l1(),l6()]),record([l1()],compressed=True)],
            time_base='1/24',media_sha256='f'*64,include_dm_blocks=True,trace_sink=trace)
        parsed=[json.loads(line) for line in trace.getvalue().splitlines()]
        self.assertEqual(result['schema_version'],5)
        self.assertTrue(result['dm_block_state_resolved'])
        self.assertFalse(result['effective_metadata_resolved'])
        self.assertEqual(parsed[0]['packet_index'],1)
        self.assertEqual(parsed[0]['dm_block_state']['blocks'][1]['source_packet_index'],0)
        self.assertEqual(parsed[0]['dm_color_state']['color_source_packet_index'],0)

if __name__=='__main__': unittest.main()
