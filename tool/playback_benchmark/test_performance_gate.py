"""Behavioral contracts for P08 qualification, immutable freezes and regressions."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).with_name('performance_gate.py')


def run_fixture():
    return dict(schemaVersion=1, runId='baseline', commit='a'*40, sourceHash='b'*64,
        dependencyHash='c'*64, artifactHash='d'*64,
        conditions=dict(caseId='owned-avc', platform='macos', device='M1', os='27',
            architecture='arm64', deviceKind='physical', buildMode='profile',
            power='ac', thermal='nominal', output='owned-window', mediaHash='e'*64,
            networkProfile='local-file', cacheState='warm', protocolHash='f'*64),
        qualification=dict(contentVerified=True, evidenceHash='1'*64),
        baselineComparable=True, plannedAttempts=4, warmupAttempts=1,
        metrics={'loadUs': {'unit':'us', 'boundary':'public-event'},
                 'rssBytes': {'unit':'bytes', 'boundary':'process-sample'},
                 'syncErrorUs': {'unit':'us', 'boundary':'calibrated-output'}},
        trials=[dict(attempt=i, outcome='passed', cleanup='passed', startedUs=i*1000,
            endedUs=i*1000+900, values={'loadUs':i*10, 'rssBytes':100+i,
                                     'syncErrorUs':None}) for i in range(1,5)])


def policy_fixture():
    return dict(schemaVersion=1, version='test-v1', minimumSamples=3, maximumNonPasses=0,
                limits={'loadUs':dict(p50=40, p95=50, maximum=60, maxRegressionRatio=0.2)})


class GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = None
        if MODULE.exists():
            spec=importlib.util.spec_from_file_location('performance_gate', MODULE)
            cls.api=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.api)

    def setUp(self):
        self.assertIsNotNone(self.api, 'P08 performance qualification/freeze engine is absent')
        self.run=run_fixture(); self.policy=policy_fixture()

    def test_warmups_retained_missing_not_zero_and_failures_visible(self):
        self.run['trials'][2]['outcome']='timeout'
        self.run['trials'][2]['values']['loadUs']=None
        result=self.api.summarize_run(self.run)
        self.assertEqual(result['attempts'],4)
        self.assertEqual(result['warmups'],1)
        self.assertEqual(result['nonPasses'],1)
        self.assertEqual(result['metrics']['loadUs']['p50'],30)
        self.assertEqual(result['metrics']['loadUs']['n'],2)
        self.assertIsNone(result['metrics']['syncErrorUs'])

    def test_setup_failure_and_cleanup_failure_are_not_success(self):
        self.run['trials'][0]['outcome']='failed'
        self.run['trials'][0]['values']={name:None for name in self.run['metrics']}
        self.run['trials'][2]['cleanup']='failed'
        result=self.api.summarize_run(self.run)
        self.assertEqual(result['nonPasses'],2)  # warmup failures also matter
        self.assertEqual(result['metrics']['loadUs']['n'],2)

    def test_qualified_freeze_and_same_condition_comparison(self):
        frozen=self.api.freeze(self.run,self.policy)
        candidate=copy.deepcopy(self.run); candidate.update(runId='after',sourceHash='2'*64,commit='3'*40,artifactHash='4'*64)
        result=self.api.evaluate(candidate,frozen)
        self.assertTrue(result['passed'])
        self.assertEqual(result['metrics']['loadUs']['improvementRatio'],0)
        candidate['trials'][3]['values']['loadUs']=200
        result=self.api.evaluate(candidate,frozen)
        self.assertFalse(result['passed'])
        self.assertIn('p95',result['metrics']['loadUs']['failures'])
        self.assertIn('regression',result['metrics']['loadUs']['failures'])

    def test_no_comparable_baseline_uses_absolute_limits(self):
        self.run['baselineComparable']=False
        frozen=self.api.freeze(self.run,self.policy)
        self.assertIsNone(self.api.evaluate(self.run,frozen)['metrics']['loadUs']['improvementRatio'])

    def test_freeze_rejects_insufficient_invalid_unqualified_baselines(self):
        for path,value in [('qualification.contentVerified',False),('qualification.evidenceHash',None),
            ('conditions.buildMode','debug'),('conditions.thermal','unknown'),('conditions.power','unknown'),
            ('plannedAttempts',5),('warmupAttempts',4)]:
            with self.subTest(path=path):
                run=copy.deepcopy(self.run); target=run; keys=path.split('.')
                for key in keys[:-1]: target=target[key]
                target[keys[-1]]=value
                with self.assertRaises(ValueError): self.api.freeze(run,self.policy)
        self.policy['minimumSamples']=4
        with self.assertRaises(ValueError): self.api.freeze(self.run,self.policy)

    def test_changed_method_device_or_cache_cannot_compare(self):
        frozen=self.api.freeze(self.run,self.policy)
        for key,value in [('cacheState','cold-controlled'),('protocolHash','2'*64),('device','other')]:
            run=copy.deepcopy(self.run);run['conditions'][key]=value
            with self.assertRaises(ValueError):self.api.evaluate(run,frozen)
        self.run['metrics']['loadUs']['boundary']='output-presented'
        with self.assertRaises(ValueError):self.api.evaluate(self.run,frozen)

    def test_presentation_and_live_metrics_require_calibration_and_source_clock(self):
        self.run['metrics']['loadUs']['boundary']='output-presented'
        with self.assertRaises(ValueError):self.api.freeze(self.run,self.policy)
        self.run['metrics']['loadUs']['boundary']='source-to-output'
        with self.assertRaises(ValueError):self.api.freeze(self.run,self.policy)

    def test_duplicate_attempt_negative_nonfinite_secret_and_extra_fields_rejected(self):
        variants=[]
        run=copy.deepcopy(self.run); run['trials'][1]['attempt']=1;variants.append(run)
        run=copy.deepcopy(self.run); run['trials'][1]['endedUs']=0;variants.append(run)
        for value in [-1,float('nan'),True]:
            run=copy.deepcopy(self.run);run['trials'][1]['values']['rssBytes']=value;variants.append(run)
        run=copy.deepcopy(self.run);run['conditions']['device']='https://secret';variants.append(run)
        run=copy.deepcopy(self.run);run['url']='secret';variants.append(run)
        for run in variants:
            with self.assertRaises(ValueError): self.api.summarize_run(run)

    def test_missing_metric_skipped_and_cancelled_cannot_pass_gate(self):
        frozen=self.api.freeze(self.run,self.policy)
        for outcome in ['skipped','cancelled','timeout','failed']:
            run=copy.deepcopy(self.run);run['trials'][2]['outcome']=outcome
            self.assertFalse(self.api.evaluate(run,frozen)['passed'])
        self.run['trials'][2]['values']['loadUs']=None
        self.assertFalse(self.api.evaluate(self.run,frozen)['passed'])

    def test_tampered_frozen_baseline_rejected(self):
        frozen=self.api.freeze(self.run,self.policy)
        frozen['baseline']['trials'][1]['values']['loadUs']=1
        with self.assertRaises(ValueError): self.api.evaluate(self.run,frozen)

    def test_cli_write_once_safe_errors_and_exit_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);run=root/'run.json';policy=root/'policy.json';frozen=root/'frozen.json'
            run.write_text(json.dumps(self.run));policy.write_text(json.dumps(self.policy))
            command=[sys.executable,str(MODULE),'freeze',str(run),str(policy),str(frozen)]
            result=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            original=frozen.read_bytes()
            self.assertEqual(subprocess.run(command,capture_output=True).returncode,2)
            self.assertEqual(frozen.read_bytes(),original)
            result=subprocess.run([sys.executable,str(MODULE),'check',str(run),str(frozen)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.run['trials'][2]['outcome']='timeout';run.write_text(json.dumps(self.run))
            self.assertEqual(subprocess.run([sys.executable,str(MODULE),'check',str(run),str(frozen)],capture_output=True).returncode,1)
            run.write_text('{"secret":"https://private-token", "secret":NaN}')
            result=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(result.returncode,2)
            self.assertNotIn('private-token',result.stdout+result.stderr)

if __name__=='__main__': unittest.main()

class PresentationClaimTests(unittest.TestCase):
    def test_all_timeouts_do_not_claim_presentation_proven(self):
        import performance_gate as gate
        baseline=run_fixture();baseline['metrics']['loadUs'].update(
            boundary='output-presented',calibrationHash='9'*64)
        frozen=gate.freeze(baseline,policy_fixture())
        candidate=copy.deepcopy(baseline)
        for trial in candidate['trials']:
            trial['outcome']='timeout';trial['values']['loadUs']=None
        result=gate.evaluate(candidate,frozen)
        self.assertFalse(result['passed'])
        self.assertNotIn('presentationProven',result)
        self.assertTrue(result['presentationMetricSelected'])
