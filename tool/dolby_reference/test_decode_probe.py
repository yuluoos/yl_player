"""Host probe integration: actual HEVC reorder, strict framing and decoder errors."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from decoded_alignment import parameter_sets, split_unit
from stream_inventory import nal_length_size


@unittest.skipUnless(os.environ.get('YL_RUN_DECODE_PROBE') == '1' and all(shutil.which(x) for x in ('ffmpeg','ffprobe','pkg-config','cc')),
                     'opt-in YL_RUN_DECODE_PROBE=1 and host FFmpeg development tools required')
class DecodeProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory(prefix='yl-decode-probe-test-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root=Path(cls.temporary.name)
        spec=importlib.util.spec_from_file_location('build_decode_probe',Path(__file__).with_name('probes')/'build_decode_probe.py')
        builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
        builder.build(cls.root/'build');cls.binary=cls.root/'build/yl-decode-layers'
        media=cls.root/'source.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=64x48:rate=6',
            '-frames:v','12','-an','-c:v','libx265','-x265-params',
            'log-level=error:pools=1:frame-threads=1:keyint=6:min-keyint=6:scenecut=0:open-gop=0:bframes=3',str(media)],
            check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=30)
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v',
            '-show_streams','-show_packets','-show_data','-show_entries',
            'stream=extradata:packet=pts,dts,pos,size','-of','json',str(media)],timeout=30))
        extra=probe['streams'][0]['extradata'];header=parameter_sets(extra)[0]
        payload=bytearray();cls.expected={};raw=media.read_bytes()
        for i,p in enumerate(probe['packets']):
            pos,size,pts,dts=(int(p[k]) for k in ('pos','size','pts','dts'))
            bl,el=split_unit(raw[pos:pos+size],nal_length_size(extra))
            if el:raise AssertionError('unexpected enhancement')
            data=(header if i==0 else b'')+bl
            payload.extend(struct.pack('>qqII',pts,dts,i,len(data))+data)
            cls.expected[i]=pts
        cls.input=bytes(payload)

    def run_probe(self,payload):
        path=self.root/'input.bin';path.write_bytes(payload)
        return subprocess.run([str(self.binary),str(path)],capture_output=True,timeout=30)

    def test_real_frames_keep_packet_tags_through_reordering_and_eof_drain(self):
        result=self.run_probe(self.input);self.assertEqual(result.returncode,0,result.stderr)
        frames=[json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(frames),12)
        self.assertEqual({f['packet_index']:f['pts'] for f in frames},self.expected)
        self.assertEqual([f['pts'] for f in frames],sorted(self.expected.values()))
        self.assertNotEqual([f['packet_index'] for f in frames],list(range(12)))
        self.assertEqual([f['poc'] for f in frames],list(range(6))*2)
        self.assertGreater(len({f['pixels_sha256'] for f in frames}),1)

    def test_malformed_or_missing_frames_never_succeed(self):
        for payload in (b'',self.input[:23],struct.pack('>qqII',0,0,0,8*1024*1024+1),
                        struct.pack('>qqII',0,0,0,4)+b'bad!',self.input[:-1],
                        self.input[:16]+struct.pack('>I',9)+self.input[20:]):
            with self.subTest(length=len(payload)):
                self.assertEqual(self.run_probe(payload).returncode,2)

if __name__=='__main__':unittest.main()
