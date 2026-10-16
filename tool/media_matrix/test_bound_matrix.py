"""Complete-catalog coverage must not be inferred from a selected passing subset."""
import copy
import base64
import hashlib
import math
import struct
import json
from pathlib import Path
import unittest
import bound_matrix
import test_bound_av as fixtures

class MatrixTest(unittest.TestCase):
    def setUp(self):
        self.catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']

    def test_inventory_preserves_all_required_and_auxiliary_cells(self):
        cells=bound_matrix.cells(self.catalog)
        self.assertEqual(44,len(cells))
        self.assertEqual(40,sum(c['requirement']=='required' for c in cells))
        self.assertEqual({'file','http'},{c['transport'] for c in cells})
        self.assertEqual(2,sum(c['requirement']=='diagnostic' for c in cells))
        self.assertEqual(2,sum(c['requirement']=='corrupt' for c in cells))
        for bad in (self.catalog[:-1],self.catalog+[self.catalog[0]]):
            with self.assertRaises(ValueError):bound_matrix.cells(bad)

    def test_child_plan_preserves_source_channels_and_transport(self):
        apple=bound_matrix.planned_case(self.catalog,'mkv-avc-opus-silk','macos','http')
        android=bound_matrix.planned_case(self.catalog,'mkv-avc-opus-silk','android','file')
        self.assertEqual((1,1,'http'),(apple['channels'],apple['sourceChannels'],apple['transport']))
        self.assertEqual((2,1,'file'),(android['channels'],android['sourceChannels'],android['transport']))
        self.assertNotIn('engine',android) # Product routing, not a forced engine.

    def test_missing_failed_or_forged_child_cannot_shrink_denominator(self):
        matrix=dict(schema=1,matrixId='matrix',platform='macos',buildSha256='a'*64,cells=bound_matrix.cells(self.catalog))
        result=bound_matrix.summarize(matrix,[])
        self.assertEqual(40,result['requiredRows'])
        self.assertFalse(result['formatScopeAcceptance'])
        self.assertEqual(0,result['supportedRows'])
        forged=dict(cell=matrix['cells'][0],plan={},rows=[],status={},artifactsUnchanged=True,result={'scopeAcceptance':True})
        self.assertFalse(bound_matrix.summarize(matrix,[forged])['formatScopeAcceptance'])
        changed=copy.deepcopy(matrix);changed['cells'].pop()
        with self.assertRaises(ValueError):bound_matrix.summarize(changed,[])

    def test_malformed_matrix_metadata_is_rejected_before_replay(self):
        matrix=dict(schema=1,matrixId='matrix',platform='macos',buildSha256='a'*64,cells=bound_matrix.cells(self.catalog))
        for key,value in [('matrixId',None),('platform','other'),('buildSha256','bad')]:
            with self.assertRaises(ValueError):bound_matrix.summarize(dict(matrix,**{key:value}),[])

    def test_raw_child_replay_rejects_cross_build_framework_failure_and_duplicate(self):
        sample=fixtures.BoundAVTest();sample.setUp()
        item=bound_matrix.planned_case(self.catalog,'mkv-avc-eac3','macos','file')
        sample.plan.update(matrixId='matrix',testSha256='b'*64,artifactKind='apple-public-flutter-debug-app',planned=[item])
        sample.row.update(testSha256='b'*64,mediaHash=item['mediaHash'],transport='file',sourceVerified=True,
            publicSessionId='player-one',publicApi='YlPlayerController/YlPlayerView',
            publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
            pixelSource='flutter-native-view-display-layer',nativeViewAttached=True,
            audioClockMethod='renderer-paused-consumption',displayReadbackProtocol='paused-layer-timebase-v1',
            windowVisibilityMethod='owned-all-spaces-window-v1')
        for phase in sample.row['phases']:
            for pixel in phase['pixels']:pixel.update(displayRate=0,windowVisible=True)
        all_cells=bound_matrix.cells(self.catalog)
        cell=next(c for c in all_cells if c['caseId']=='mkv-avc-eac3' and c['transport']=='file')
        matrix=dict(schema=1,matrixId='matrix',platform='macos',buildSha256='b'*64,cells=all_cells)
        record=dict(cell=cell,plan=sample.plan,rows=[sample.row],artifactsUnchanged=True,exitCode=0,
            status=dict(passed=True,identityVerified=True,artifactsUnchanged=True,runId='run-one'))
        self.assertEqual(1,bound_matrix.summarize(matrix,[record])['supportedRows'])
        for update in ({'exitCode':1},{'exitCode':None},{'exitCode':False},{'collectorError':'failed read'}):
            bad=copy.deepcopy(record);bad.update(update)
            self.assertEqual(0,bound_matrix.summarize(matrix,[bad])['supportedRows'])
        for key in ('matrixId','buildSha256','artifactKind'):
            bad=copy.deepcopy(record);bad['plan'][key]='borrowed'
            self.assertEqual(0,bound_matrix.summarize(matrix,[bad])['supportedRows'])
        bad=copy.deepcopy(record);bad['status']['passed']=False
        self.assertEqual(0,bound_matrix.summarize(matrix,[bad])['supportedRows'])
        bad=copy.deepcopy(record);bad['rows'][0]['phases'][0]['pcmWindows'][0]['pcmSha256']='forged'
        self.assertEqual(0,bound_matrix.summarize(matrix,[bad])['supportedRows'])
        self.assertIn('duplicate_or_unplanned_cell',bound_matrix.summarize(matrix,[record,record])['errors'])

    def test_android_extraction_is_replayed_without_accepting_a_valid_prefix(self):
        rows=[{'caseId':'sample'}]
        raw=json.dumps(rows[0]).encode()+b'\n'
        record=dict(rows=rows,extractedJsonlBase64=base64.b64encode(raw).decode(),extractExit=0)
        self.assertTrue(bound_matrix.extraction_valid('android',record))
        for bad in (dict(record,extractExit=1),dict(record,extractExit=False),
                    dict(record,extractedJsonlBase64=None),dict(record,rows=[]),
                    dict(record,extractedJsonlBase64=base64.b64encode(raw+b'bad trailing row').decode())):
            self.assertFalse(bound_matrix.extraction_valid('android',bad))

    def test_complete_raw_matrix_accepts_only_with_final_product_and_frameworks(self):
        all_cells=bound_matrix.cells(self.catalog)
        matrix=dict(schema=1,matrixId='matrix',platform='macos',buildSha256='b'*64,
            cells=all_cells,artifactFinalVerified=True)
        records=[];payloads={}
        for index,cell in enumerate(all_cells):
            sample=fixtures.BoundAVTest();sample.setUp()
            item=bound_matrix.planned_case(self.catalog,cell['caseId'],'macos',cell['transport'])
            run=f'child-{index}'
            sample.plan.update(runId=run,matrixId='matrix',testSha256='b'*64,
                artifactKind='apple-public-flutter-debug-app',planned=[item])
            sample.row.update(runId=run,testSha256='b'*64,caseId=cell['caseId'],mediaHash=cell['mediaHash'],
                transport=cell['transport'],sourceVerified=True,networkPolicy='managed',
                networkReceipt=dict(runId=run,mediaHash=cell['mediaHash'],requests=1,bytesServed=100,rejected=0),
                publicSessionId='player-one',publicApi='YlPlayerController/YlPlayerView',
                publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
                pixelSource='flutter-native-view-display-layer',nativeViewAttached=True,
                audioClockMethod='renderer-paused-consumption',displayReadbackProtocol='paused-layer-timebase-v1',
                windowVisibilityMethod='owned-all-spaces-window-v1')
            for phase in sample.row['phases']:
                phase['runId']=run
                for pixel in phase['pixels']:pixel.update(displayRate=0,windowVisible=True)
                for window in phase['pcmWindows']:
                    channels=item['channels'];marker=window['marker'];key=(channels,marker)
                    if key not in payloads:
                        frequencies=[440+220*marker,495+220*marker,550+220*marker,60+10*marker,660+220*marker,715+220*marker][:channels]
                        raw=struct.pack('<'+'f'*(8192*channels),*(.04*math.sin(2*math.pi*f*i/48000) for i in range(8192) for f in frequencies))
                        payloads[key]=(base64.b64encode(raw).decode(),hashlib.sha256(raw).hexdigest())
                    encoded,digest=payloads[key]
                    window.update(runId=run,channels=channels,pcmF32LE=encoded,pcmSha256=digest)
            records.append(dict(cell=cell,plan=sample.plan,rows=[sample.row],artifactsUnchanged=True,exitCode=0,
                status=dict(passed=True,identityVerified=True,artifactsUnchanged=True,runId=run)))
        result=bound_matrix.summarize(matrix,records)
        self.assertEqual(40,result['supportedRows']);self.assertTrue(result['formatScopeAcceptance'])
        self.assertFalse(result['fullAcceptance'])
        self.assertFalse(bound_matrix.summarize(dict(matrix,artifactFinalVerified=False),records)['formatScopeAcceptance'])
        records[0]['status']['passed']=False
        result=bound_matrix.summarize(matrix,records)
        self.assertEqual(39,result['supportedRows']);self.assertFalse(result['formatScopeAcceptance'])

if __name__=='__main__':unittest.main()
