import unittest
from mapping_references import resolve
from stream_inventory import InspectionError

class MappingReferenceTests(unittest.TestCase):
    def value(self,identifier,mapping=None):
        return {'use_previous_mapping':mapping is None,'previous_mapping_id':identifier if mapping is None else None,
                'mapping':dict(vdr_rpu_id=identifier,curves=mapping) if mapping is not None else None}

    def test_references_use_decode_order_and_id_not_previous_display_frame(self):
        values=[self.value(0,[1]),self.value(1,[2]),self.value(0),self.value(1)]
        result=resolve(values)
        self.assertEqual([r['mapping_source_packet_index'] for r in result],[0,1,0,1])
        self.assertEqual(result[0]['mapping_sha256'],result[2]['mapping_sha256'])
        self.assertNotEqual(result[0]['mapping_sha256'],result[1]['mapping_sha256'])

    def test_redefinition_replaces_only_its_id_and_new_epoch_has_no_history(self):
        values=[self.value(0,[1]),self.value(1,[2]),self.value(0,[3]),self.value(1),self.value(0)]
        self.assertEqual([r['mapping_source_packet_index'] for r in resolve(values)],[0,1,2,1,2])
        with self.assertRaises(InspectionError):resolve([self.value(0)])

    def test_invalid_or_ambiguous_reference_fails_closed(self):
        bad=[self.value(16,[1]),self.value(-1,[1]),self.value(True,[1]),self.value(2),
             dict(self.value(0,[1]),use_previous_mapping=True),
             dict(self.value(0,[1]),previous_mapping_id=0)]
        for value in bad:
            with self.subTest(value=value),self.assertRaises(InspectionError):resolve([value])

if __name__=='__main__':unittest.main()
