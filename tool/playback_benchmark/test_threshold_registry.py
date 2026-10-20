import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE=Path(__file__).with_name('threshold_registry.py')

class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(),'threshold registry is not executable')
        spec=importlib.util.spec_from_file_location('threshold_registry',MODULE)
        self.api=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.api)
        self.registry=json.loads(MODULE.with_name('thresholds.json').read_text())

    def test_pending_profiles_are_explicit_blockers(self):
        result=self.api.check(self.registry,MODULE.parents[2])
        self.assertFalse(result['ready']);self.assertEqual(len(result['blockers']),4)
        self.assertEqual(result['passed'],0)

    def test_empty_or_duplicate_profiles_never_green(self):
        self.registry['requiredProfiles']=[]
        with self.assertRaises(ValueError):self.api.check(self.registry,MODULE.parents[2])
        self.registry=json.loads(MODULE.with_name('thresholds.json').read_text())
        self.registry['requiredProfiles'].append(self.registry['requiredProfiles'][0])
        with self.assertRaises(ValueError):self.api.check(self.registry,MODULE.parents[2])

    def test_unknown_and_escaping_evidence_rejected(self):
        for path in ['../secret','/private/tmp/secret']:
            self.registry['entries']=[dict(profile='android-api24-low-memory',frozen=dict(path=path,sha256='a'*64),
                candidate=dict(path=path,sha256='a'*64),sources=dict(path=path,sha256='a'*64))]
            with self.assertRaises(ValueError):self.api.check(self.registry,MODULE.parents[2])

if __name__=='__main__':unittest.main()

class ProfileCoverageTests(unittest.TestCase):
    def test_exact_profile_constraints_are_enforced(self):
        import threshold_registry as registry
        self.assertTrue(hasattr(registry,'matches_profile'))
        base={'platform':'macos','deviceKind':'physical','os':'27.0.1','architecture':'arm64'}
        intel={'platform':'macos','deviceKind':'physical','constraints':{'osMajor':12,'architectures':['x86_64']}}
        self.assertFalse(registry.matches_profile(base,intel))
        self.assertFalse(registry.matches_profile({**base,'architecture':'x86_64'},intel))
        self.assertFalse(registry.matches_profile({**base,'os':'12.7'},intel))
        self.assertTrue(registry.matches_profile({**base,'os':'12.7','architecture':'x86_64'},intel))
        android={'platform':'android','deviceKind':'physical','constraints':{'apiLevel':24,'processBits':32,'memoryClass':'low'}}
        phone={'platform':'android','deviceKind':'physical','apiLevel':24,'processBits':32,'memoryClass':'low'}
        self.assertTrue(registry.matches_profile(phone,android))
        for key,value in [('apiLevel',36),('processBits',64),('memoryClass','standard')]:
            self.assertFalse(registry.matches_profile({**phone,key:value},android))
        self.assertFalse(registry.matches_profile({'platform':'android','deviceKind':'physical'},android))

class RegistrySourceIntegrationTests(unittest.TestCase):
    def test_real_registry_rejects_wrong_profile_and_invalidates_native_changes(self):
        import subprocess
        import hashlib
        import threshold_registry as registry
        import performance_gate as gate
        from run_public_stress import source_identity
        from test_performance_gate import run_fixture, policy_fixture
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);subprocess.run(['git','init','-q',str(root)],check=True)
            native=root/'packages/core/src/decoder.cpp';native.parent.mkdir(parents=True);native.write_text('before')
            sources=source_identity(root);candidate=run_fixture();candidate['sourceHash']=gate.digest(sources)
            frozen=gate.freeze(candidate,policy_fixture())
            def save(name,value):
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(gate.canonical(value))
                return dict(path=name,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            profile=dict(id='macos-apple-silicon',platform='macos',deviceKind='physical',constraints={'architectures':['arm64']},nextAction='collect')
            data=dict(schemaVersion=1,status='frozen',requiredProfiles=[profile],entries=[dict(profile=profile['id'],
                frozen=save('docs/frozen.json',frozen),candidate=save('docs/candidate.json',candidate),sources=save('docs/sources.json',sources))])
            self.assertTrue(registry.check(data,root)['ready'])
            profile['constraints']={'architectures':['x86_64'],'osMajor':12}
            with self.assertRaises(ValueError):registry.check(data,root)
            profile['constraints']={'architectures':['arm64']}
            native.write_text('changed decoder')
            result=registry.check(data,root)
            self.assertFalse(result['ready']);self.assertEqual(result['blockers'][0]['reason'],'source-changed')
