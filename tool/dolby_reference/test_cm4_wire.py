"""Raw CM4 rejection and long-form transport, never a display quality claim."""
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
import test_compressed_cm4
from decoded_alignment import decode
from dm_block_state import resolve
from stream_inventory import InspectionError,file_digest


class Cm4WireTests(test_compressed_cm4.CompressedCm4Tests):
    __unittest_skip__ = os.environ.get('YL_RUN_CM4_WIRE') != '1'
    __unittest_skip_why__ = 'opt-in CM4 wire tests require long/raw fixtures and both parsers'
    fixture_environment = 'YL_DOVI_LONG_CM4_FIXTURE'

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        binary=Path(os.environ['YL_DOVI_RAW_CM4_FIXTURE']).resolve(strict=True)
        cls.raw_root=cls.root/'raw-cases'
        cls.cases=json.loads(subprocess.check_output([str(binary),str(cls.raw_root)],timeout=30))
        if len(cls.cases)!=6:raise AssertionError('raw negative fixture coverage changed')

    def test_long_coordinate_bits_are_bound_to_correct_frames(self):
        trace=io.BytesIO()
        decode(self.media,file_digest(self.media),self.inspector,self.decoder,trace_sink=trace,include_metadata=True)
        rows=[json.loads(line) for line in trace.getvalue().splitlines()]
        self.assertEqual(len(rows),12)
        for row in rows:
            index=row['packet_index'];blocks=row['dm_block_state']['blocks']
            l10=[b for b in blocks if b['level']==10]
            self.assertEqual(len(l10),int(index%4<2))
            if l10:
                self.assertEqual(l10[0]['payload']['length'],21)
                self.assertEqual(l10[0]['payload']['target_primary_white_y'],10747)
                self.assertEqual(l10[0]['source_packet_index'],index-index%2)
            l9=[b for b in blocks if b['level']==9]
            if index%2:
                self.assertEqual(l9[0]['payload']['length'],17)
                self.assertEqual(l9[0]['source_packet_index'],index)
                self.assertEqual(l9[0]['payload']['source_primary_red_x'],32768 if index%4==3 else 20001)
                self.assertEqual(l9[0]['payload']['source_primary_red_y'],65535 if index%4==3 else 10001)

    def test_crc_valid_raw_cases_fail_at_parser_or_state_without_trace(self):
        original=Path(os.environ['YL_DOVI_UPSTREAM_INSPECTOR']).resolve(strict=True)
        prefix=self.root/'complete-prefix.rpus';prefix.write_bytes(self.records[0])
        full=json.loads(subprocess.check_output([str(self.inspector),str(prefix),'--dm-color'],timeout=30))
        for case in self.cases:
            with self.subTest(case=case['name']):
                path=self.raw_root/case['file']
                for binary,expected in ((self.inspector,case['patched_parse']),(original,case['upstream_parse'])):
                    result=subprocess.run([str(binary),str(path),'--dm-color'],capture_output=True,timeout=30)
                    self.assertEqual(result.returncode,0 if expected else 2)
                    if expected:
                        rows=[json.loads(line) for line in result.stdout.splitlines()]
                        self.assertEqual(len(rows),1)
                        with self.assertRaises(InspectionError):resolve([full,*rows])
                # Preserve a valid first record so context errors cannot be
                # explained away as an orphan compressed RPU.
                records=self.records*3;records[1]=path.read_bytes()
                bad=self.make_media('bad-'+case['name'],records)
                trace=io.BytesIO()
                with self.assertRaises(InspectionError):
                    decode(bad,file_digest(bad),self.inspector,self.decoder,trace_sink=trace,include_metadata=True)
                self.assertEqual(trace.getvalue(),b'')

if __name__=='__main__':unittest.main()
