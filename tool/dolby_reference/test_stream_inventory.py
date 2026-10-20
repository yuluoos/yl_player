"""Offline extraction/aggregation tests; synthetic inputs are not DV evidence."""
import hashlib
import io
import json
from pathlib import Path
import unittest
import tempfile
import sys
import subprocess

from stream_inventory import (InspectionError, extract_rpus, summarize,
                              nal_length_size, run_bounded, file_digest)


def packet(data, pts=0, dts=0, pos=0):
    return {'stream_index': 0, 'pts': pts, 'dts': dts,
            'pos': str(pos), 'size': str(len(data))}


def nal(kind, body=b'payload'):
    data = bytes([kind << 1, 1]) + body
    return len(data).to_bytes(4, 'big') + data


def box(kind, body=b''):
    return (8+len(body)).to_bytes(4, 'big') + kind + body


def parsed():
    return {'profile': 5, 'el_type': None, 'cm_levels': {'2.9': [1, 2, 4, 5, 6]},
            'display_metadata': {'scene_refresh_flag': 1, 'value': 20},
            'use_previous_mapping': False, 'unparsed_rpu_bits': 0}


class StreamInventoryTests(unittest.TestCase):
    def test_mapping_references_are_resolved_before_presentation_reordering(self):
        rows=[dict(packet_index=0,pts=2,dts=0,rpu_sha256='a'*64),
              dict(packet_index=1,pts=1,dts=1,rpu_sha256='b'*64)]
        first=dict(parsed(),mapping={'vdr_rpu_id':3,'curves':[1]},previous_mapping_id=None)
        reuse=dict(parsed(),mapping=None,previous_mapping_id=3,use_previous_mapping=True)
        trace=io.BytesIO()
        result=summarize(rows,[first,reuse],time_base='1/24',media_sha256='f'*64,
                         trace_sink=trace,include_mapping=True)
        decoded=[json.loads(line) for line in trace.getvalue().splitlines()]
        self.assertEqual(result['schema_version'],3)
        self.assertTrue(result['mapping_reference_ids_resolved'])
        self.assertFalse(result['effective_metadata_resolved'])
        self.assertEqual(decoded[0]['packet_index'],1)
        self.assertEqual(decoded[0]['mapping_reference']['mapping_source_packet_index'],0)

    def test_mapping_rejects_rows_reordered_before_resolution(self):
        rows=[dict(packet_index=1,pts=1,dts=0,rpu_sha256='a'*64),
              dict(packet_index=0,pts=0,dts=1,rpu_sha256='b'*64)]
        value=dict(parsed(),mapping={'vdr_rpu_id':0},previous_mapping_id=None)
        with self.assertRaises(InspectionError):
            summarize(rows,[value,value],time_base='1/24',media_sha256='f'*64,include_mapping=True)

    def test_hvcc_length_size_is_read_from_bytes_not_assumed(self):
        for size in [1, 2, 3, 4]:
            hvcc = bytearray(23); hvcc[0] = 1; hvcc[21] = 0xfc | (size - 1)
            dump = '\n' + '\n'.join(f'{i:08x}: {bytes(hvcc[i:i+16]).hex(" ")}  ignored'
                                      for i in range(0, len(hvcc), 16))
            self.assertEqual(nal_length_size(dump), size)
        for invalid in ['', '\n00000000: 00  ignored', 'PRIVATE']:
            with self.assertRaises(InspectionError): nal_length_size(invalid)

    def test_extraction_preserves_original_bytes_and_integer_timestamps(self):
        data = nal(32) + nal(19) + nal(62)
        rows, framed = extract_rpus(io.BytesIO(data), [packet(data, pts=2**53+1, dts=-2)],
                                   length_size=4, stream_index=0, media_size=len(data))
        original = bytes([124, 1]) + b'payload'
        self.assertEqual(framed, len(original).to_bytes(4, 'big') + original)
        self.assertEqual(rows[0]['pts'], 2**53+1)
        self.assertEqual(rows[0]['dts'], -2)
        self.assertEqual(rows[0]['rpu_sha256'], hashlib.sha256(original).hexdigest())

    def test_truncated_lengths_zero_nals_and_headers_are_rejected(self):
        for data in [b'\x00', b'\x00'*4, (8).to_bytes(4, 'big')+b'xx',
                     (2).to_bytes(4, 'big')+b'\xfc\x01',
                     (2).to_bytes(4, 'big')+b'\x7c\x00']:
            with self.subTest(data=data), self.assertRaises(InspectionError):
                extract_rpus(io.BytesIO(data), [packet(data)], length_size=4,
                             stream_index=0, media_size=len(data))

    def test_missing_duplicate_and_out_of_file_packets_fail_closed(self):
        data=nal(19)+nal(62); base=packet(data)
        for packets in [[], [base, base], [dict(base, pts='N/A')],
                        [dict(base, pos='-1')], [dict(base, size=str(len(data)+1))],
                        [dict(base, stream_index=2)]]:
            with self.assertRaises(InspectionError):
                extract_rpus(io.BytesIO(data), packets, length_size=4,
                             stream_index=0, media_size=len(data))

    def test_rpu_limits_and_multiple_rpus_in_one_picture_are_explicit_failures(self):
        for data in [nal(19)+nal(62,b'x'*65536), nal(19)+nal(62)+nal(62), nal(19)]:
            with self.assertRaises(InspectionError):
                extract_rpus(io.BytesIO(data), [packet(data)], length_size=4,
                             stream_index=0, media_size=len(data))

    def test_dynamic_metadata_is_counted_in_presentation_order_without_acceptance(self):
        rows=[{'packet_index':0,'pts':1,'dts':0,'rpu_sha256':'a'*64},
              {'packet_index':1,'pts':0,'dts':1,'rpu_sha256':'b'*64}]
        a=parsed(); b=parsed(); b['display_metadata']['value']=30
        result=summarize(rows,[a,b],time_base='1/24000',media_sha256='c'*64)
        self.assertEqual(result['rpu_count'],2)
        self.assertEqual(result['display_metadata_transitions'],1)
        self.assertEqual(result['pts_range'],[0,1])
        self.assertEqual(result['presentation_reordered_packets'],2)
        self.assertEqual(result['level_counts'],{'1':2,'2':2,'4':2,'5':2,'6':2})
        self.assertEqual(result['mapping_quality'],'external_missing')
        self.assertEqual(result['native_dv_signal'],'external_missing')
        self.assertFalse(result['effective_metadata_resolved'])

    def test_parser_output_cardinality_unknown_levels_and_reuse_remain_visible(self):
        row={'packet_index':0,'pts':0,'dts':0,'rpu_sha256':'a'*64}
        for data in [[],[parsed(),parsed()]]:
            with self.assertRaises(InspectionError):
                summarize([row],data,time_base='1/24',media_sha256='c'*64)
        value=parsed();value['cm_levels']={'4.0':[8,42]};value['use_previous_mapping']=True;value['unparsed_rpu_bits']=7
        result=summarize([row],[value],time_base='1/24',media_sha256='c'*64)
        self.assertEqual(result['level_counts'],{'8':1,'42':1})
        self.assertEqual(result['previous_mapping_rpus'],1)
        self.assertEqual(result['cm_counts'],{'4.0':1})
        self.assertEqual(result['rpus_with_unparsed_bits'],1)

    def test_trace_is_hash_bound_and_uses_integer_presentation_order(self):
        rows=[{'packet_index':0,'pts':20,'dts':0,'rpu_sha256':'a'*64},
              {'packet_index':1,'pts':10,'dts':1,'rpu_sha256':'b'*64}]
        trace=io.BytesIO()
        result=summarize(rows,[parsed(),parsed()],time_base='1/24',
                         media_sha256='c'*64,trace_sink=trace)
        self.assertEqual(result['presentation_trace_sha256'],
                         hashlib.sha256(trace.getvalue()).hexdigest())
        self.assertEqual([json.loads(line)['pts'] for line in trace.getvalue().splitlines()],[10,20])

    def test_hashing_enforces_byte_limit_while_reading(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'input';path.write_bytes(b'abcd')
            with self.assertRaises(InspectionError): file_digest(path,limit=3)
            self.assertEqual(file_digest(path,limit=4),hashlib.sha256(b'abcd').hexdigest())

    def test_subprocess_limits_failure_and_timeout_have_safe_errors(self):
        import sys
        for script,limit,timeout in [('print("PRIVATE")',2,2),
                                     ('import time; time.sleep(2)',100,.02),
                                     ('raise RuntimeError("PRIVATE")',100,2)]:
            with self.assertRaises(InspectionError) as caught:
                run_bounded([sys.executable,'-c',script],limit=limit,timeout=timeout)
            self.assertNotIn('PRIVATE',str(caught.exception))
        self.assertEqual(run_bounded([sys.executable,'-c','print("ok")']),b'ok\n')

class CollectorCliTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.media=self.root/'PRIVATE_MEDIA.mp4'
        self.data=nal(19)+nal(62)
        self.container=box(b'ftyp',b'isom')+box(b'moov')+box(b'mdat',self.data)
        self.media.write_bytes(self.container)
        hvcc=bytearray(23);hvcc[0]=1;hvcc[21]=3
        dump='\n'+'\n'.join(f'{i:08x}: {bytes(hvcc[i:i+16]).hex(" ")}  text'
                              for i in range(0,len(hvcc),16))
        self.probe_data={'streams':[{'index':0,'codec_name':'hevc','codec_type':'video',
                            'time_base':'1/24','extradata':dump,'nb_frames':'1'}],
                         'packets':[packet(self.data,pos=len(self.container)-len(self.data))]}
        self.probe=self.script('probe', 'import json; print('+repr(json.dumps(self.probe_data))+')')
        expected=(len(b'\x7c\x01payload')).to_bytes(4,'big')+b'\x7c\x01payload'
        self.inspector=self.script('inspector',
            'import pathlib,sys; assert pathlib.Path(sys.argv[1]).read_bytes()=='+repr(expected)+
            '; print('+repr(json.dumps(parsed()))+')')
        self.sha=hashlib.sha256(self.container).hexdigest()

    def script(self,name,body):
        path=self.root/name;path.write_text('#!'+sys.executable+'\n'+body+'\n');path.chmod(0o700)
        return path

    def cli(self,*extra):
        return subprocess.run([sys.executable,'-B',str(Path(__file__).with_name('stream_inventory.py')),
            '--media',str(self.media),'--sha256',self.sha,
            '--inspector',str(self.inspector),'--ffprobe',str(self.probe),*map(str,extra)],
            capture_output=True,text=True,timeout=5)

    def test_packet_bytes_reach_inspector_and_trace_is_exclusive(self):
        trace=self.root/'trace.jsonl';result=self.cli('--trace',trace)
        self.assertEqual(result.returncode,0,result.stdout)
        report=json.loads(result.stdout)
        self.assertEqual(report['presentation_trace_sha256'],hashlib.sha256(trace.read_bytes()).hexdigest())
        self.assertEqual(trace.stat().st_mode & 0o777,0o600)
        original=trace.read_bytes();again=self.cli('--trace',trace)
        self.assertEqual(again.returncode,2)
        self.assertEqual(trace.read_bytes(),original)

    def test_incomplete_or_unknown_declared_sample_count_is_refused(self):
        for count in ['2', '0', 'N/A', None]:
            with self.subTest(count=count):
                self.probe_data['streams'][0]['nb_frames']=count
                self.probe=self.script('probe', 'print('+repr(json.dumps(self.probe_data))+')')
                trace=self.root/'trace.jsonl'
                result=self.cli('--trace',trace)
                self.assertEqual(result.returncode,2,result.stdout)
                self.assertFalse(trace.exists())

    def test_truncated_box_or_fragmented_container_is_refused(self):
        # Keep the full first packet but declare that mdat contains more bytes.
        mdat_offset=len(self.container)-len(self.data)-8
        malformed=self.container[:mdat_offset]+(8+len(self.data)+100).to_bytes(4,'big')+self.container[mdat_offset+4:]
        for data in [malformed, self.container+b'xx', self.container+box(b'moof'),
                     self.container[:mdat_offset]+bytes(4)+self.container[mdat_offset+4:]]:
            with self.subTest(data=data):
                self.media.write_bytes(data);self.sha=hashlib.sha256(data).hexdigest()
                result=self.cli()
                self.assertEqual(result.returncode,2,result.stdout)

    def test_packets_outside_mdat_are_refused(self):
        # Valid NAL bytes in a free box cannot be mistaken for track media.
        data=box(b'free',self.data)+self.container
        self.media.write_bytes(data);self.sha=hashlib.sha256(data).hexdigest()
        self.probe_data['packets'][0]['pos']='8'
        self.probe=self.script('probe','print('+repr(json.dumps(self.probe_data))+')')
        self.assertEqual(self.cli().returncode,2)

    def test_symlink_output_preserves_existing_target(self):
        target=self.root/'target';target.write_bytes(b'original')
        trace=self.root/'trace.jsonl';trace.symlink_to(target)
        result=self.cli('--trace',trace)
        self.assertEqual(result.returncode,2);self.assertEqual(target.read_bytes(),b'original')

    def test_partial_parser_output_on_failure_never_becomes_success(self):
        self.inspector=self.script('failed', 'import sys; print('+repr(json.dumps(parsed()))+'); sys.exit(2)')
        trace=self.root/'trace.jsonl';result=self.cli('--trace',trace)
        self.assertEqual(result.returncode,2);self.assertFalse(trace.exists())
        self.assertNotIn('PRIVATE',result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['mapping_quality'],'external_missing')

    def test_media_hash_mismatch_stops_before_probe(self):
        marker=self.root/'ran'
        self.probe=self.script('never', 'from pathlib import Path; Path('+repr(str(marker))+').touch()')
        self.sha='0'*64
        result=self.cli()
        self.assertEqual(result.returncode,2);self.assertFalse(marker.exists())

    def test_inspector_mutation_cannot_claim_the_new_binary_produced_results(self):
        self.inspector=self.script('self_modify',
            'from pathlib import Path; Path(__file__).write_text("changed"); print('+repr(json.dumps(parsed()))+')')
        result=self.cli()
        self.assertEqual(result.returncode,2)

    def test_media_mutation_during_inspection_cannot_publish_a_report(self):
        self.inspector=self.script('mutate','from pathlib import Path; Path('+repr(str(self.media))+').write_bytes(b"changed"); print('+repr(json.dumps(parsed()))+')')
        result=self.cli()
        self.assertEqual(result.returncode,2)
        self.assertNotIn('PRIVATE',result.stdout+result.stderr)

if __name__ == '__main__': unittest.main()
