"""Decoded provenance must survive B-frame reordering and reject partial output."""
import copy
import unittest
import decoded_alignment as alignment
from stream_inventory import InspectionError


class AlignmentTests(unittest.TestCase):
    def rows(self):
        return [dict(packet_index=i, pts=pts, dts=i-2, rpu_sha256=str(i)*64,
                     use_previous_mapping=False) for i,pts in enumerate((0,2,1))]

    def frames(self):
        return [dict(packet_index=i, pts=pts, width=1920, height=1080,
                     poc=pts, pixel_format='yuv420p10le', picture_type='I' if i==0 else 'B',
                     pixels_sha256='a'*64) for i,pts in ((0,0),(2,1),(1,2))]

    def test_associates_real_decoder_packet_tags_in_presentation_order(self):
        result=alignment.pair_frames(self.rows(),self.frames(),self.frames())
        self.assertEqual([r['packet_index'] for r in result],[0,2,1])
        self.assertEqual([r['rpu_sha256'] for r in result],['0'*64,'2'*64,'1'*64])
        self.assertEqual(result[1]['base']['pixels_sha256'],'a'*64)

    def test_rejects_missing_duplicate_wrong_timestamp_or_packet_tag(self):
        cases=[self.frames()[:-1],self.frames()+[self.frames()[0]]]
        for key,value in [('pts',99),('poc',99),('packet_index',99),('width',0),('pixels_sha256','bad')]:
            frames=self.frames();frames[1][key]=value;cases.append(frames)
        for frames in cases:
            with self.subTest(frames=frames),self.assertRaises(InspectionError):
                alignment.pair_frames(self.rows(),self.frames(),frames)

    def test_requires_strict_display_order_and_same_layer_coverage(self):
        with self.assertRaises(InspectionError):
            alignment.pair_frames(self.rows(),self.frames(),list(reversed(self.frames())))
        rows=self.rows();rows[1]['pts']=rows[0]['pts']
        with self.assertRaises(InspectionError):alignment.pair_frames(rows,self.frames(),self.frames())

    def test_reused_mapping_is_not_silently_resolved_by_adjacent_frame(self):
        rows=self.rows();rows[2]['use_previous_mapping']=True
        result=alignment.pair_frames(rows,self.frames(),None)
        self.assertTrue(result[1]['use_previous_mapping'])
        self.assertIsNone(result[1]['enhancement'])
        self.assertNotIn('effective_metadata_sha256',result[1])


class AccessUnitTests(unittest.TestCase):
    def nal(self,kind,first=True): return bytes([kind<<1,1,128 if first else 0,20])
    def pack(self,*nals): return b''.join(len(n).to_bytes(4,'big')+n for n in nals)

    def test_unwraps_enhancement_without_changing_inner_bytes(self):
        base=self.nal(1);el=self.nal(1);rpu=self.nal(62)
        b,e=alignment.split_unit(self.pack(base,self.nal(63)[:2]+el,rpu),4)
        self.assertEqual(b,b'\0\0\0\1'+base)
        self.assertEqual(e,b'\0\0\0\1'+el)

    def test_refuses_two_pictures_truncation_and_nested_wrapper(self):
        bad=[self.pack(self.nal(1),self.nal(1)),self.pack(self.nal(1))[:-1],
             self.pack(self.nal(1),self.nal(63)[:2]+self.nal(63))]
        for data in bad:
            with self.assertRaises(InspectionError):alignment.split_unit(data,4)

if __name__=='__main__':unittest.main()
