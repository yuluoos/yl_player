"""The audit must reject unreviewed numeric and enum behavior changes."""
import importlib.util
from pathlib import Path
import unittest
import tempfile

GATE = Path(__file__).resolve().parents[3] / 'packages/yl_player_apple/tool/behavioral_constants.py'

class BehavioralConstantsTests(unittest.TestCase):
    def test_numeric_and_enum_mutations_are_observable_but_comments_are_not(self):
        spec = importlib.util.spec_from_file_location('behavioral_constants', GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = 'enum Retry { case idle, waiting }; let budget = 500_000 // 999\n'
        tokens = module.extract(original)
        self.assertNotEqual(tokens, module.extract(original.replace('500_000', '600_000')))
        self.assertNotEqual(tokens, module.extract(original.replace('waiting', 'retrying')))
        self.assertEqual(tokens, module.extract(original.replace('// 999', '// 123')))
        self.assertNotEqual(module.extract('let flags = [._1xRealTimePlayback]'), module.extract('let flags = [._EnableTemporalProcessing]'))
        self.assertNotEqual(module.difference(tokens, tokens), module.difference(tokens, module.extract('let budget = 5')))

    def test_range_lower_and_upper_bound_mutations_are_observable(self):
        spec = importlib.util.spec_from_file_location('behavioral_constants', GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for operator in ('...', '..<'):
            for lower, upper in (('500', '599'), ('1', '8'), ('-2', '0'), ('1.5', '2.5')):
                expression = f'({lower}{operator}{upper}).contains(value)'
                tokens = module.extract(expression)
                with self.subTest(expression=expression):
                    self.assertIn('number:' + lower, tokens)
                    self.assertIn('number:' + upper, tokens)
                    for bound, changed in ((lower, '3'), (upper, '16')):
                        with self.subTest(bound=bound):
                            self.assertNotEqual(tokens, module.extract(expression.replace(bound, changed, 1)))

    def test_actual_retry_and_audio_range_mutations_are_observable(self):
        spec = importlib.util.spec_from_file_location('behavioral_constants', GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        root = GATE.parents[3]
        sources = root / 'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple'
        for path, original, mutations in (
            ('Engines/AvPlayer/YlAvPlayerRecoveryPolicy.swift', '500...599', ('400...599', '500...699')),
            ('Shared/Audio/YlAudioRenderer.swift', '1...8', ('2...8', '1...16')),
        ):
            text = (sources / path).read_text()
            self.assertIn(original, text)
            for mutation in mutations:
                with self.subTest(path=path, mutation=mutation):
                    self.assertNotEqual(module.extract(text), module.extract(text.replace(original, mutation)))

class ExtractionConstantsTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location('behavioral_constants', GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_extraction_preserves_multiplicity_and_rejects_literal_changes(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'old.swift').write_text('let a = 2; let b = 2')
            (root / 'a.swift').write_text('let a = 2')
            (root / 'b.swift').write_text('let b = 2')
            row = dict(old_file='old.swift', new_files=['a.swift', 'b.swift'],
                       old_tokens=module.extract((root / 'old.swift').read_text()),
                       allowed_delta={}, reason='import/platform abstraction: extraction')
            self.assertEqual(module.verify(root, [row]), [])
            for mutation in ('let b = 3', '', 'let b = 2; let c = 2'):
                (root / 'b.swift').write_text(mutation)
                self.assertTrue(module.verify(root, [row]), mutation)

    def test_invalid_ambiguous_missing_and_duplicate_paths_fail_closed(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'old.swift').write_text('let a = 2')
            (root / 'a.swift').write_text('let a = 2')
            base = dict(old_file='old.swift', old_tokens={'number:2': 1},
                        allowed_delta={}, reason='import/platform abstraction: extraction')
            for paths in ([], ['a.swift', 'a.swift'], ['missing.swift'], ['../a.swift'],
                          ['/a.swift'], ['a.swift', './a.swift'], ['*.swift'], ['']):
                with self.subTest(paths=paths):
                    self.assertTrue(module.verify(root, [dict(base, new_files=paths)]))
            self.assertTrue(module.verify(root, [dict(base, new_file='a.swift', new_files=['a.swift'])]))
            self.assertTrue(module.verify(root, [base]))

if __name__ == '__main__':
    unittest.main()
