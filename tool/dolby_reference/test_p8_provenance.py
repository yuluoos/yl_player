"""Generated P8 transport integration; never an independent Dolby quality target."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import unittest

from decoded_alignment import decode, parameter_sets, split_unit
from stream_inventory import InspectionError, file_digest, nal_length_size


@unittest.skipUnless(os.environ.get('YL_RUN_P8_PROVENANCE') == '1',
                     'opt-in P8 provenance requires host FFmpeg and pinned Rust inspector/fixture')
class P8ProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='yl-p8-provenance-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.inspector = Path(os.environ['YL_DOVI_INSPECTOR']).resolve(strict=True)
        cls.fixture = Path(os.environ['YL_DOVI_CM_FIXTURE']).resolve(strict=True)
        probes = Path(__file__).with_name('probes')
        spec = importlib.util.spec_from_file_location('build_decode_probe', probes/'build_decode_probe.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        builder.build(cls.root/'decoder'); cls.decoder = cls.root/'decoder/yl-decode-layers'
        flags = shlex.split(subprocess.check_output(
            ['pkg-config','--cflags','--libs','libavformat','libavcodec','libavutil'], text=True, timeout=30))
        cls.mux = cls.root/'mux'
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror',
                        str(probes/'mux_rpu_fixture.c'),'-o',str(cls.mux),*flags], check=True, timeout=30)
        cls.source = cls.root/'source.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=64x48:rate=6',
            '-frames:v','12','-an','-c:v','libx265','-pix_fmt','yuv420p10le','-x265-params',
            'log-level=error:pools=1:frame-threads=1:keyint=6:min-keyint=6:scenecut=0:open-gop=0:bframes=3',
            str(cls.source)], check=True, capture_output=True, timeout=30)
        framed = subprocess.check_output([str(cls.fixture)], timeout=30)
        cls.records = []; offset = 0
        while offset < len(framed):
            size = int.from_bytes(framed[offset:offset+4], 'big')
            if not 3 <= size <= len(framed)-offset-4: raise AssertionError('invalid fixture framing')
            cls.records.append(framed[offset:offset+4+size]); offset += 4+size
        if len(cls.records) != 4: raise AssertionError('expected full/compressed/reset/compressed')
        cls.media = cls.make_media('valid', cls.records*3)

    @classmethod
    def make_media(cls, name, records):
        rpus = cls.root/(name+'.rpus'); rpus.write_bytes(b''.join(records))
        media = cls.root/(name+'.mp4')
        subprocess.run([str(cls.mux),str(cls.source),str(rpus),str(media)],
                       check=True,capture_output=True,timeout=30)
        return media

    @classmethod
    def probe(cls, media):
        return json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v',
            '-show_streams','-show_packets','-show_data','-show_entries',
            'stream=time_base,extradata:packet=pts,dts,pos,size','-of','json',str(media)],timeout=30))

    def test_real_decode_binds_compressed_state_across_reorder_and_reset(self):
        trace = io.BytesIO()
        summary = decode(self.media,file_digest(self.media),self.inspector,self.decoder,
                         trace_sink=trace,include_metadata=True)
        rows = [json.loads(line) for line in trace.getvalue().splitlines()]
        self.assertEqual(summary['schema_version'],2)
        self.assertEqual(summary['decoded_frames'],12)
        self.assertEqual(summary['compressed_dm_color_rpus'],6)
        self.assertEqual(summary['previous_mapping_rpus'],6)
        self.assertEqual(summary['inherited_static_block_instances'],6)
        self.assertFalse(summary['enhancement_decoded'])
        self.assertFalse(summary['effective_metadata_resolved'])
        self.assertEqual(summary['mapping_quality'],'external_missing')
        self.assertNotEqual([r['packet_index'] for r in rows],list(range(12)))
        self.assertEqual([r['base']['poc'] for r in rows],list(range(6))*2)
        by_packet = {r['packet_index']: r for r in rows}
        for r in rows:
            index = r['packet_index']; origin = index-index%2
            self.assertEqual(r['profile'],8)
            self.assertIsNone(r['enhancement'])
            self.assertEqual(r['base']['packet_index'],index)
            self.assertEqual(r['base']['pts'],r['pts'])
            self.assertEqual(r['base']['pixel_format'],'yuv420p10le')
            self.assertEqual(r['mapping_reference']['mapping_source_packet_index'],origin)
            self.assertEqual(r['dm_color_state']['color_source_packet_index'],origin)
            blocks = r['dm_block_state']['blocks']
            self.assertEqual({b['level'] for b in blocks if b['static']},
                             {6,254} if index%4 < 2 else set())
            for b in blocks:
                self.assertEqual(b['source_packet_index'],origin if b['static'] else index)
            if index%2:
                self.assertEqual({b['level'] for b in blocks if not b['static']},{1,5})
            self.assertEqual(r['dm_color_state']['color_sha256'],
                             by_packet[origin]['dm_color_state']['color_sha256'])
        # At least one inheritance source lies later in presentation order: a
        # display-neighbor implementation must not accidentally satisfy this case.
        self.assertTrue(any(by_packet[r['dm_color_state']['color_source_packet_index']]['pts'] > r['pts']
                            for r in rows))
        # Verify exact source packet timestamps/BL bytes independently of metadata,
        # then compare actual decoder output with the no-RPU source's output.
        source = self.probe(self.source); muxed = self.probe(self.media)
        self.assertEqual(source['streams'][0]['time_base'],muxed['streams'][0]['time_base'])
        original = self.source.read_bytes(); modified = self.media.read_bytes()
        header = parameter_sets(source['streams'][0]['extradata'])[0]
        framed = bytearray()
        for index,(a,b) in enumerate(zip(source['packets'],muxed['packets'],strict=True)):
            self.assertEqual((a['pts'],a['dts']),(b['pts'],b['dts']))
            def unit(raw,p): return raw[int(p['pos']):int(p['pos'])+int(p['size'])]
            self.assertEqual(unit(modified,b),unit(original,a)+self.records[index%4])
            base,el = split_unit(unit(original,a),nal_length_size(source['streams'][0]['extradata']))
            self.assertEqual(el,b'')
            payload = (header if index==0 else b'')+base
            framed.extend(struct.pack('>qqII',int(a['pts']),int(a['dts']),index,len(payload))+payload)
        input_file = self.root/'source.framed'; input_file.write_bytes(framed)
        baseline = [json.loads(line) for line in subprocess.check_output(
            [str(self.decoder),str(input_file)],timeout=30).splitlines()]
        self.assertEqual([r['base'] for r in rows],baseline)
        legacy = io.BytesIO()
        old_summary = decode(self.media,file_digest(self.media),self.inspector,self.decoder,trace_sink=legacy)
        self.assertEqual(old_summary['schema_version'],1)
        self.assertTrue(all('dm_block_state' not in json.loads(line) for line in legacy.getvalue().splitlines()))

    def test_orphan_compressed_state_fails_without_publishing_trace(self):
        bad = self.make_media('orphan',[self.records[1]]+self.records[1:]+self.records*2)
        trace = io.BytesIO()
        with self.assertRaises(InspectionError):
            decode(bad,file_digest(bad),self.inspector,self.decoder,trace_sink=trace,include_metadata=True)
        self.assertEqual(trace.getvalue(),b'')

    def test_mux_fixture_refuses_missing_or_extra_rpu_records(self):
        for count in (11,13):
            rpus = self.root/f'wrong-{count}.rpus'
            rpus.write_bytes(b''.join((self.records*4)[:count]))
            result = subprocess.run([str(self.mux),str(self.source),str(rpus),str(self.root/f'wrong-{count}.mp4')],
                                    capture_output=True,timeout=30)
            self.assertEqual(result.returncode,2)

if __name__=='__main__': unittest.main()
