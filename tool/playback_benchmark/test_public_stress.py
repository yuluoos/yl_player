import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import run_public_stress as runner
from test_performance_gate import run_fixture

class PublicStressTests(unittest.TestCase):
    def test_complete_single_run_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'log'
            path.write_text('unrelated\nYL_PERFORMANCE_RUN='+json.dumps(run_fixture())+'\n')
            self.assertEqual(runner.extract(path)['plannedAttempts'],4)
            for text in ['', 'YL_PERFORMANCE_RUN={}\n',
                         'YL_PERFORMANCE_RUN='+json.dumps(run_fixture())+'\nYL_PERFORMANCE_RUN={}\n']:
                path.write_text(text)
                with self.assertRaises(ValueError):runner.extract(path)

    def test_device_model_uses_safe_reversible_label(self):
        self.assertTrue(hasattr(runner,'model_label'))
        self.assertEqual(runner.model_label('Mac15,12'),'Mac15-12')
        with self.assertRaises(ValueError):runner.model_label('https://private-token')

    def test_setup_failure_always_retains_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'fresh'
            with patch.object(runner,'source_identity',side_effect=ValueError('secret')):
                self.assertFalse(runner.collect(path,'missing-flutter'))
            receipt=(path/'result.json').read_text()
            self.assertNotIn('secret',receipt)
            self.assertFalse(json.loads(receipt)['complete'])

if __name__=='__main__':unittest.main()

class SourceIdentityTests(unittest.TestCase):
    def test_native_c_cpp_and_build_inputs_invalidate_identity(self):
        import subprocess
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            subprocess.run(['git','init','-q',str(root)],check=True)
            paths=['packages/native/src/runtime.c','packages/native/src/decoder.cpp',
                   'packages/native/CMakeLists.txt','packages/native/build.gradle',
                   'packages/native/src/player.mm']
            for name in paths:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('before')
            before=runner.source_identity(root)
            for name in paths:
                with self.subTest(path=name):
                    self.assertIn(name,before)
                    path=root/name;path.write_text('after')
                    self.assertNotEqual(runner.source_identity(root),before)
                    path.write_text('before')
