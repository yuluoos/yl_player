"""Comparator tests use explicit synthetic references, never Dolby golden claims."""
import array
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from pixel_compare import ComparisonError, validate_contract, compare_bundle


class BundleFixture(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        evidence=self.asset('proof.txt', b'synthetic operator-reviewed fixture; not DV evidence')
        self.contract={'schema_version':1,'mode':'reviewed_reference','source_sha256':'a'*64,
            'width':2,'height':2,'domain':'linear_nits_bt2020',
            'target':{'peak_nits':1000,'black_nits':0.005,'primaries':'bt2020',
                      'white_point':[0.3127,0.329],'transfer':'pq','ambient_lux':5},
            'active_area':[0,0,2,1],
            'regions':[{'name':'bottom','kind':'boundary','rect':[0,1,2,1]},
                       {'name':'left','kind':'chroma_edge','rect':[0,0,1,2]}],
            'thresholds':{'max_abs_nits':1,'rmse_nits':1,'p99_abs_nits':1},
            'evidence':[{**evidence,'role':role} for role in
                        ['provenance','frame_alignment','target_generation','threshold_basis']],
            'frames':[{'id':i,'pts':[i,24],'metadata_sha256':str(i+1)*64,
                       'reference':self.pixels(f'ref-{i}.f32',[10]*12)} for i in range(2)]}
        self.capture={'schema_version':1,'source_sha256':'a'*64,
            'width':2,'height':2,'domain':self.contract['domain'],
            'target':copy.deepcopy(self.contract['target']),'display_generation':7,
            'frames':[{'id':i,'pts':[i,24],'metadata_sha256':str(i+1)*64,
                       'display_generation':7,'actual':self.pixels(f'actual-{i}.f32',[10]*12)} for i in range(2)]}
        self.save()

    def asset(self,name,data):
        (self.root/name).write_bytes(data)
        return {'path':name,'sha256':hashlib.sha256(data).hexdigest()}

    def pixels(self,name,values):
        a=array.array('f',values)
        if sys.byteorder!='little':a.byteswap()
        return self.asset(name,a.tobytes())

    def save(self):
        raw=json.dumps(self.contract,allow_nan=False).encode();self.sha=hashlib.sha256(raw).hexdigest()
        (self.root/'contract.json').write_bytes(raw)
        self.capture['contract_sha256']=self.sha
        (self.root/'capture.json').write_text(json.dumps(self.capture,allow_nan=False))

    def compare(self):
        self.save()
        return compare_bundle(self.root/'contract.json',self.sha,self.root/'capture.json')


class ContractTests(BundleFixture):
    def test_thresholds_regions_and_target_parameters_are_checked(self):
        validate_contract(self.contract)
        mutations=[('thresholds',{'max_abs_nits':-1,'rmse_nits':1,'p99_abs_nits':1}),
                   ('width',True),('height',9999999),('active_area',[0,0,3,2]),('regions',[])]
        for key,value in mutations:
            c=copy.deepcopy(self.contract);c[key]=value
            with self.subTest(key=key),self.assertRaises(ComparisonError):validate_contract(c)
        for value in [float('nan'),float('inf'),True,-1]:
            c=copy.deepcopy(self.contract);c['target']['black_nits']=value
            with self.assertRaises(ComparisonError):validate_contract(c)

    def test_reviewed_requires_multiframe_dynamic_metadata_and_proof_roles(self):
        for change in ['one_frame','same_metadata','missing_proof','duplicate_id']:
            c=copy.deepcopy(self.contract)
            if change=='one_frame':c['frames']=c['frames'][:1]
            if change=='same_metadata':c['frames'][1]['metadata_sha256']=c['frames'][0]['metadata_sha256']
            if change=='missing_proof':c['evidence']=c['evidence'][:-1]
            if change=='duplicate_id':c['frames'][1]['id']=0
            with self.subTest(change=change),self.assertRaises(ComparisonError):validate_contract(c)


@unittest.skipUnless(importlib.util.find_spec('numpy'), 'Research pixel comparison requires requirements-reference.txt (NumPy)')
class PixelComparisonTests(BundleFixture):
    def test_full_active_and_edges_report_exact_metrics_and_location(self):
        self.capture['frames'][0]['actual']=self.pixels('changed.f32',[12]+[10]*11)
        result=self.compare();self.assertEqual(result['comparison_status'],'fail')
        full=result['frames'][0]['regions']['full']
        self.assertEqual(full['max_abs_nits'],2)
        self.assertAlmostEqual(full['rmse_nits'],(4/12)**0.5)
        self.assertEqual(full['p99_abs_nits'],2)
        self.assertEqual(full['max_error_at'],[0,0,0])
        self.assertEqual(result['frames'][0]['regions']['bottom']['max_abs_nits'],0)
        self.assertIsNone(result['mapping_quality_pass'])
        self.assertIsNone(result['native_dv_signal_pass'])

    def test_candidate_never_returns_pass_even_when_identical(self):
        self.contract['mode']='candidate';self.contract['evidence']=[]
        result=self.compare()
        self.assertTrue(result['numeric_thresholds_met'])
        self.assertEqual(result['comparison_status'],'diagnostic')

    def test_reference_identity_hash_and_path_are_enforced(self):
        (self.root/'ref-0.f32').write_bytes(b'x'*48)
        with self.assertRaises(ComparisonError):self.compare()
        self.contract['frames'][0]['reference']['path']='../escape.f32'
        with self.assertRaises(ComparisonError):self.compare()

    def test_contract_hash_is_checked_before_comparison(self):
        with self.assertRaises(ComparisonError):
            compare_bundle(self.root/'contract.json','0'*64,self.root/'capture.json')

    def test_target_generation_color_time_and_metadata_mismatch_are_rejected(self):
        original=copy.deepcopy(self.capture)
        for change in ['target','generation','domain','time','metadata','source','count']:
            self.capture=copy.deepcopy(original)
            if change=='target':self.capture['target']['peak_nits']=600
            if change=='generation':self.capture['frames'][0]['display_generation']=6
            if change=='domain':self.capture['domain']='linear_nits_p3d65'
            if change=='time':self.capture['frames'][1]['pts']=[2,24]
            if change=='metadata':self.capture['frames'][0]['metadata_sha256']='b'*64
            if change=='source':self.capture['source_sha256']='b'*64
            if change=='count':self.capture['frames']=self.capture['frames'][:1]
            with self.subTest(change=change),self.assertRaises(ComparisonError):self.compare()

    def test_all_pixels_including_excluded_active_area_must_be_finite(self):
        for value in [float('nan'),float('inf')]:
            self.capture['frames'][0]['actual']=self.pixels('nonfinite.f32',[10]*11+[value])
            with self.assertRaises(ComparisonError):self.compare()

    def test_no_rescale_or_normalization_and_exact_rational_pts(self):
        self.capture['frames'][0]['actual']=self.pixels('scaled.f32',[20]*12)
        self.capture['frames'][1]['pts']=[2,48]
        result=self.compare();self.assertEqual(result['frames'][0]['regions']['full']['max_abs_nits'],10)
        self.assertEqual(result['comparison_status'],'fail')

    def test_cli_safe_failures_and_candidate_exit_code(self):
        command=[sys.executable,'-B',str(Path(__file__).with_name('pixel_compare.py')),
                 '--contract',str(self.root/'contract.json'),'--sha256',self.sha,
                 '--capture',str(self.root/'capture.json')]
        result=subprocess.run(command,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.contract['mode']='candidate';self.save();command[command.index('--sha256')+1]=self.sha
        result=subprocess.run(command,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,3)
        (self.root/'capture.json').write_text('{"PRIVATE":')
        result=subprocess.run(command,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,2)
        self.assertNotIn(str(self.root),result.stdout+result.stderr)
        self.assertNotIn('PRIVATE',result.stdout+result.stderr)

    def test_review_evidence_tampering_and_wrong_pixel_length_are_rejected(self):
        (self.root/'proof.txt').write_bytes(b'changed proof')
        with self.assertRaises(ComparisonError):self.compare()
        self.contract['mode']='candidate';self.contract['evidence']=[]
        for data in [b'\x00'*44,b'\x00'*52]:
            self.capture['frames'][0]['actual']=self.asset('wrong-length.f32',data)
            with self.assertRaises(ComparisonError):self.compare()

    def test_integer_pts_above_float_precision_are_not_aliased(self):
        base=2**53+1
        for i in range(2):
            self.contract['frames'][i]['pts']=[base+i,24]
            self.capture['frames'][i]['pts']=[base+i,24]
        self.assertEqual(self.compare()['comparison_status'],'pass')
        self.capture['frames'][0]['pts']=[base-1,24]
        with self.assertRaises(ComparisonError):self.compare()

    def test_missing_numpy_is_an_explicit_dependency_failure(self):
        result=subprocess.run([sys.executable,'-S',str(Path(__file__).with_name('pixel_compare.py')),
            '--contract',str(self.root/'contract.json'),'--sha256',self.sha,
            '--capture',str(self.root/'capture.json')],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['code'],'dolby.reference_numpy_missing')

    def test_cli_cyclic_symlinks_are_safe_invalid_input(self):
        loop=self.root/'PRIVATE-loop'
        loop.symlink_to(loop.name)
        contract_before=copy.deepcopy(self.contract)
        capture_before=copy.deepcopy(self.capture)
        for where in ('contract','capture','reference','actual','evidence'):
            with self.subTest(where=where):
                self.contract=copy.deepcopy(contract_before)
                self.capture=copy.deepcopy(capture_before)
                if where=='reference':self.contract['frames'][0]['reference']['path']=loop.name
                if where=='actual':self.capture['frames'][0]['actual']['path']=loop.name
                if where=='evidence':self.contract['evidence'][0]['path']=loop.name
                self.save()
                contract=loop if where=='contract' else self.root/'contract.json'
                capture=loop if where=='capture' else self.root/'capture.json'
                result=subprocess.run([sys.executable,'-B',str(Path(__file__).with_name('pixel_compare.py')),
                    '--contract',str(contract),'--sha256',self.sha,'--capture',str(capture)],
                    capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,2,result.stdout+result.stderr)
                self.assertEqual(json.loads(result.stdout),{'code':'dolby.reference_comparison_invalid'})
                self.assertEqual(result.stderr,'')
                self.assertNotIn('PRIVATE',result.stdout)
