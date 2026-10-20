"""Synthetic metadata tests establish parser behavior, not Dolby quality."""
from fractions import Fraction
import hashlib
import struct
import tempfile
from pathlib import Path
import unittest
from reference_timeline import ReferenceError, parse_mdf, locate_frame, locate_pts, exr_header, verify_publisher_asset


def xml(shots=None, rate='60000', denominator='1001'):
    if shots is None:
        shots = '<Shot><Record><In>0</In><Duration>2</Duration></Record></Shot><Shot><Record><In>2</In><Duration>3</Duration></Record><PluginNode><DolbyEDR level="2"><TID>1</TID></DolbyEDR></PluginNode></Shot>'
    return f'''<DolbyLabsMDF version="2.0.5"><Outputs><Output><Video><Track>
    <Rate><n>{rate}</n><d>{denominator}</d></Rate><PluginNode><DolbyEDR><Characteristics>
    <TargetDisplay><ID>1</ID><Name>test</Name><PeakBrightness>100</PeakBrightness></TargetDisplay>
    </Characteristics></DolbyEDR></PluginNode>{shots}</Track></Video></Output></Outputs></DolbyLabsMDF>'''.encode()


def exr(attrs):
    return struct.pack('<II', 20000630, 2) + b''.join(name.encode()+b'\0'+kind.encode()+b'\0'+struct.pack('<I', len(value))+value for name,kind,value in attrs) + b'\0'


class ReferenceTimelineTests(unittest.TestCase):
    def test_exact_rate_and_half_open_shot_boundaries(self):
        timeline = parse_mdf(xml())
        self.assertEqual(locate_frame(timeline, 1)['shot_index'], 0)
        match = locate_frame(timeline, 2)
        self.assertEqual(match['shot_index'], 1)
        self.assertEqual(match['time'], [1001, 30000])
        self.assertEqual(match['signalled_trim_targets'], ['1'])
        self.assertFalse(match['cross_sequence_alignment_verified'])
        self.assertEqual(locate_pts(timeline, 2002, [1,60000]), match)
        for frame in [-1,5,True]:
            with self.assertRaises(ReferenceError): locate_frame(timeline, frame)
        with self.assertRaises(ReferenceError): locate_pts(timeline,1,[1,60000])

    def test_large_integer_frames_are_not_rounded_through_float(self):
        n=2**53+1
        timeline=parse_mdf(xml(f'<Shot><Record><In>0</In><Duration>{n+2}</Duration></Record></Shot>', '24','1'))
        self.assertEqual(locate_pts(timeline,n,[1,24])['frame_index'],n)

    def test_timeline_gaps_overlap_duplicate_targets_and_ambiguous_tracks_fail(self):
        for start in [1,3]:
            data=xml(f'<Shot><Record><In>0</In><Duration>2</Duration></Record></Shot><Shot><Record><In>{start}</In><Duration>2</Duration></Record></Shot>')
            with self.assertRaises(ReferenceError):parse_mdf(data)
        for data in [xml(denominator='0'),xml().replace(b'</Track>', b'</Track><Track/>'),
                     xml().replace(b'</Characteristics>', b'<TargetDisplay><ID>1</ID></TargetDisplay></Characteristics>'),
                     xml().replace(b'<TID>1</TID>',b'<TID>2</TID>'),
                     b'<!DOCTYPE x [<!ENTITY e "x">]>'+xml(), xml()[:-10]]:
            with self.subTest(data=data[:40]),self.assertRaises(ReferenceError):parse_mdf(data)

    def test_exr_raw_timecode_is_not_used_as_frame_identity(self):
        data=exr([('framesPerSecond','rational',struct.pack('<iI',60000,1001)),
                  ('dataWindow','box2i',struct.pack('<4i',0,0,4095,2159)),
                  ('timeCode','timecode',bytes.fromhex('0016000000000000'))])
        info=exr_header(data)
        self.assertEqual(info['rate'],[60000,1001])
        self.assertEqual(info['data_window'],[0,0,4095,2159])
        self.assertEqual(info['timecode_raw'],'0016000000000000')
        self.assertIsNone(info['frame_index'])
        for bad in [data[:-1],b'bad',exr([('x','int',b'abcd'),('x','int',b'efgh')])]:
            with self.assertRaises(ReferenceError):exr_header(bad)

    def test_publisher_checksum_binds_exact_local_bytes_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'input.exr';path.write_bytes(b'original')
            sha=hashlib.sha256(b'original').hexdigest()
            checksum=b'frame.exr\t8\tmd5\t'+hashlib.md5(b'original').hexdigest().encode()+b'\n'
            checksum_sha=hashlib.sha256(checksum).hexdigest()
            result=verify_publisher_asset(path,sha,checksum,checksum_sha,'frame.exr')
            self.assertTrue(result['publisher_checksum_matches'])
            self.assertEqual(result['media_sha256'],sha)
            for data,expected in [(checksum,'0'*64),(checksum+checksum,hashlib.sha256(checksum+checksum).hexdigest()),
                                  (checksum.replace(b'\t8\t',b'\t7\t'),hashlib.sha256(checksum.replace(b'\t8\t',b'\t7\t')).hexdigest())]:
                with self.assertRaises(ReferenceError):verify_publisher_asset(path,sha,data,expected,'frame.exr')
            path.write_bytes(b'modified')
            with self.assertRaises(ReferenceError):verify_publisher_asset(path,sha,checksum,checksum_sha,'frame.exr')
