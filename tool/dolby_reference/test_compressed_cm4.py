"""Synthetic CM4 cross-parser integration; no mapping quality qualification."""
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import unittest
import test_p8_provenance
from decoded_alignment import decode
from stream_inventory import file_digest


@unittest.skipUnless(os.environ.get('YL_RUN_CM4_PROVENANCE') == '1',
                     'opt-in compressed CM4 requires patched inspector and fixture')
class CompressedCm4Tests(test_p8_provenance.P8ProvenanceTests):
    # Do not inherit the separate P8 opt-in's skip flag.
    __unittest_skip__ = os.environ.get('YL_RUN_CM4_PROVENANCE') != '1'
    fixture_environment = 'YL_DOVI_CM4_FIXTURE'

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.oracle=cls.root/'ffmpeg-cm4'
        flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs',
            'libavformat','libavcodec','libavutil'],text=True,timeout=30))
        subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror',
            str(Path(__file__).with_name('probes')/'cm4_ffmpeg_fixture.c'),'-o',str(cls.oracle),*flags],
            check=True,timeout=30)

    def test_real_decode_binds_compressed_state_across_reorder_and_reset(self):
        trace=io.BytesIO()
        summary=decode(self.media,file_digest(self.media),self.inspector,self.decoder,
                       trace_sink=trace,include_metadata=True)
        rows=[json.loads(line) for line in trace.getvalue().splitlines()]
        raw=subprocess.run([str(self.oracle),str(self.media)],capture_output=True,timeout=30)
        self.assertEqual(raw.returncode,0,raw.stderr.decode())
        independently_parsed=[json.loads(line) for line in raw.stdout.splitlines()]
        self.assertEqual(len(rows),12)
        self.assertEqual(len(independently_parsed),12)
        self.assertEqual(summary['compressed_dm_color_rpus'],6)
        self.assertEqual(summary['inherited_static_block_instances'],12)
        self.assertFalse(summary['effective_metadata_resolved'])
        self.assertEqual(summary['mapping_quality'],'external_missing')
        self.assertNotEqual([r['packet_index'] for r in rows],list(range(12)))
        self.assertEqual([r['base']['poc'] for r in rows],list(range(6))*2)
        for row,other in zip(rows,independently_parsed,strict=True):
            self.assertEqual(row['pts'],other['pts'])
            index=row['packet_index'];origin=index-index%2
            self.assertEqual(row['dm_color_state']['color_source_packet_index'],origin)
            self.assertEqual(row['mapping_reference']['mapping_source_packet_index'],origin)
            blocks=row['dm_block_state']['blocks']
            self.assertEqual({b['level'] for b in blocks if b['static']},
                             {6,10,254} if index%4<2 else {254})
            for b in blocks:self.assertEqual(b['source_packet_index'],origin if b['static'] else index)
            if index%2:
                self.assertEqual({b['level'] for b in blocks if not b['static']},{1,3,8,9,11})
                self.assertEqual([b['payload']['length'] for b in blocks if b['level']==8],
                                 [10,12,13,19,25] if index%4==1 else [25])
            # FFmpeg stores optional L8 fields as zero without wire length. Compare
            # all transmitted fields and separately require absent fields to be zero.
            def key(b):return (b['level'],b['payload'].get('target_display_index',-1))
            actual=sorted(other['blocks'],key=key);expected=sorted(blocks,key=key)
            self.assertEqual([key(b) for b in actual],[key(b) for b in expected])
            for a,b in zip(actual,expected,strict=True):
                payload={k:v for k,v in b['payload'].items() if k!='length'}
                for key,value in payload.items():
                    if '_primary_' in key and key.endswith(('_x','_y')):
                        # FFmpeg n8.0.1 reads signed 16-bit / 32767; libdovi
                        # preserves the u16 wire word. Compare without floats.
                        signed=value if value<32768 else value-65536
                        self.assertEqual(a['payload'][key],[signed,32767])
                    else:
                        self.assertEqual(a['payload'][key],value)
                self.assertTrue(all(v==0 for k,v in a['payload'].items() if k not in payload))

    def test_unmodified_parser_refuses_raw_compressed_cm4(self):
        original=Path(os.environ['YL_DOVI_UPSTREAM_INSPECTOR']).resolve(strict=True)
        result=subprocess.run([str(original),str(self.root/'valid.rpus'),'--dm-color'],
                              capture_output=True,timeout=30)
        self.assertEqual(result.returncode,2)

if __name__=='__main__':unittest.main()
