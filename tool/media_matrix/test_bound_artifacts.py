"""Frozen code identity must survive collection without trusting source revisions."""
import pathlib
import tempfile
import unittest
from bound_artifacts import freeze, verify

class ArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)
        (self.root/'product').write_bytes(b'actual executable')
    def test_real_bytes_and_deterministic_manifest(self):
        record=freeze(self.root)
        self.assertEqual(record,freeze(self.root)); self.assertTrue(verify(self.root,record))
        self.assertEqual(record['files'][0]['path'],'product')
    def test_mutation_addition_and_deletion_rejected(self):
        for operation in ('change','add','delete'):
            with self.subTest(operation=operation):
                (self.root/'product').write_bytes(b'actual executable'); record=freeze(self.root)
                if operation=='change':(self.root/'product').write_bytes(b'new executable')
                if operation=='add':(self.root/'extra').write_bytes(b'new')
                if operation=='delete':(self.root/'product').unlink()
                self.assertFalse(verify(self.root,record))
                (self.root/'extra').unlink(missing_ok=True)
    def test_excludes_test_bundle_but_not_product_code(self):
        tests=self.root/'PlugIns'/'RunnerTests.xctest'; tests.mkdir(parents=True)
        (tests/'RunnerTests').write_bytes(b'test code')
        product=freeze(self.root,exclude_tests=True); harness=freeze(tests)
        (tests/'RunnerTests').write_bytes(b'new test code')
        self.assertTrue(verify(self.root,product)); self.assertFalse(verify(tests,harness))
    def test_symlink_target_code_is_bound(self):
        (self.root/'alias').symlink_to('product')
        record=freeze(self.root)
        self.assertEqual(len(record['files']),1)
        (self.root/'product').write_bytes(b'changed target')
        self.assertFalse(verify(self.root,record))

if __name__=='__main__':unittest.main()
