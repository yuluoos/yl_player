import unittest
from attribute_decoded_heap import parse_heap, compare_tables, selected_type

RAW = '''Process: yl_player_example [42]
All zones: 6 nodes (224 bytes)
 COUNT BYTES AVG CLASS_NAME TYPE BINARY
 ===== ===== === ========== ==== ======
 2 64 32.0   Closure context   Swift   <unknown>
 1 64 64.0   Some Type With Spaces   Swift   example.dylib
 1 32 32.0   SameName   C++   First
 1 32 32.0   SameName   CFType   Second
 1 32 32.0   non-object
'''

class DecodedHeapAttributionTests(unittest.TestCase):
    def test_preserves_class_type_binary_and_untyped_rows(self):
        result=parse_heap(RAW,42)
        self.assertEqual(result['totals'],[6,224])
        self.assertEqual(len(result['rows']),5)
        self.assertEqual(result['rows'][1]['className'],'Some Type With Spaces')
        self.assertIsNone(result['rows'][-1]['type'])

    def test_rejects_wrong_pid_truncated_extra_and_malformed_rows(self):
        for raw in (RAW.replace('[42]','[43]'),'Process: yl_player_example [999]\n'+RAW,
                    'Process: yl_player_example [42]\n'+RAW,RAW.replace(' 1 32 32.0   non-object\n',''),
                    RAW+' 1 32 32.0   Extra   ObjC   App\n',
                    RAW+' unknown row\n',RAW.replace('6 nodes','7 nodes')):
            with self.subTest(raw=raw),self.assertRaises(ValueError):parse_heap(raw,42)

    def test_absent_type_is_unidentified_not_zero(self):
        table=parse_heap(RAW,42)
        self.assertIsNone(selected_type(table,'AVAudioPCMBuffer','ObjC','AVFAudio'))
        self.assertEqual(selected_type(table,'Closure context','Swift','<unknown>')['count'],2)

    def test_deltas_reconcile_totals_without_merging_same_named_types(self):
        before=parse_heap(RAW,42)
        after=parse_heap(RAW.replace('6 nodes (224 bytes)','7 nodes (256 bytes)').replace('2 64 32.0','3 96 32.0'),42)
        delta=compare_tables(before,after)
        self.assertEqual(delta['totalDelta'],[1,32])
        self.assertEqual(sum(r['bytesDelta'] for r in delta['rows']),32)
        self.assertEqual(len([r for r in delta['rows'] if r['className']=='SameName']),2)

    def test_unlisted_endpoint_keeps_null_and_only_computes_listing_delta(self):
        before=parse_heap(RAW,42)
        after=parse_heap(RAW.replace('6 nodes (224 bytes)','5 nodes (160 bytes)').replace(' 1 64 64.0   Some Type With Spaces   Swift   example.dylib\n',''),42)
        row=next(r for r in compare_tables(before,after)['rows'] if r['className']=='Some Type With Spaces')
        self.assertIsNone(row['after'])
        self.assertEqual(row['bytesDelta'],-64)
        self.assertFalse(row['bothListed'])

    def test_repeated_exact_labels_preserve_rows_and_aggregate_counts(self):
        table=parse_heap(RAW.replace('SameName   CFType   Second','SameName   C++   First'),42)
        self.assertEqual(len(table['rows']),5)
        group=selected_type(table,'SameName','C++','First')
        self.assertEqual((group['count'],group['bytes'],group['tableRows']),(2,64,2))
        self.assertEqual(compare_tables(table,table)['totalDelta'],[0,0])

    def test_named_malloc_without_type_keeps_binary(self):
        raw=RAW.replace('Some Type With Spaces   Swift   example.dylib','__DataStorage._bytes (malloc)            Foundation')
        row=parse_heap(raw,42)['rows'][1]
        self.assertIsNone(row['type'])
        self.assertEqual(row['binary'],'Foundation')

    def test_compact_delta_reconciles_top_rows_and_remainder(self):
        from attribute_decoded_heap import compact_comparison
        table=parse_heap(RAW,42)
        after=parse_heap(RAW.replace('6 nodes (224 bytes)','7 nodes (256 bytes)').replace('2 64 32.0','3 96 32.0'),42)
        value=compact_comparison(compare_tables(table,after))
        self.assertEqual(value['summedRowDelta'],value['totalDelta'])
        self.assertEqual(sum(r['bytesDelta'] for r in value['topIncreases']+value['topDecreases'])+
                         value['remainingIncreaseBytes']+value['remainingDecreaseBytes'],32)


class ArchivedDecodedAttributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import json
        from pathlib import Path
        cls.path=Path(__file__).with_name('macos-decoded-resource-length-observations.json')
        cls.archive=json.loads(cls.path.read_text())

    def test_all_eighteen_archived_heaps_reconcile(self):
        from attribute_decoded_heap import analyze_archive
        value=analyze_archive(self.path)
        self.assertEqual(len(value['cells']),6)
        for cell in value['cells']:
            self.assertEqual(len(cell['sources']),3)
            for comparison in cell['comparisons'].values():
                self.assertEqual(comparison['summedRowDelta'],comparison['totalDelta'])
        self.assertFalse(value['causalityProven'])
        self.assertEqual(value['baselineAdjusted60Minus4']['legacy']['totalBytesDelta'],1631664)
        for contrast in value['baselineAdjusted60Minus4'].values():
            self.assertEqual(contrast['namedFourBytesDelta']+contrast['untypedBytesDelta']+contrast['otherListedBytesDelta'],contrast['totalBytesDelta'])

    def test_rejects_modified_raw_digest_and_probe_pid(self):
        import copy,json,tempfile
        from pathlib import Path
        from attribute_decoded_heap import analyze_archive
        for change in ('digest','pid','identity','probeBytes'):
            data=copy.deepcopy(self.archive)
            if change=='digest':
                entry=next(e for e in data['raw'] if e['path']=='yl-length-final-4-legacy/drained-heap.txt')
                entry['sha256']='0'*64
            elif change=='pid':data['observations'][0]['result']['probes'][0]['pid']+=1
            elif change=='identity':data['identity']['baseCommit']='unrelated'
            else:data['observations'][0]['result']['probes'][0]['bytes']+=1
            with tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'archive.json';path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):analyze_archive(path)
