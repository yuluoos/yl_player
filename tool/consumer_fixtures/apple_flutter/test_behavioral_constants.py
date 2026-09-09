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

class StructuralFoldTests(unittest.TestCase):
    def module(self):
        return ExtractionConstantsTests().module()

    def fixture(self, root):
        import hashlib
        old = "final class Session {\n  func stop() { audio.anchor = false }\n  func seek() { audio.anchor = false }\n}\n"
        caller = "final class Session {\n  let audio: Audio\n  func stop() { audio.resetAnchor() }\n  func seek() { audio.resetAnchor() }\n}\n"
        owner = "final class Audio {\n  func resetAnchor() { anchor = false }\n}\n"
        (root / 'session.swift').write_text(caller)
        (root / 'audio.swift').write_text(owner)
        fold = dict(id='anchor', ruling='R11', before_revision='pinned',
                    before_file='session.swift', before_sha256=hashlib.sha256(old.encode()).hexdigest(),
                    before_owner='Session', before_statement='audio.anchor = false',
                    before_count=2, token='symbol:false', after_file='audio.swift',
                    after_owner='Audio', after_method='resetAnchor', after_body='anchor = false',
                    after_count=1, caller_file='session.swift', caller_owner='Session',
                    call='audio.resetAnchor()', lifecycle_methods=['stop', 'seek'],
                    current_scope=['session.swift', 'audio.swift'], legacy_files=['old.swift'])
        row = dict(old_file='old.swift', new_files=fold['current_scope'], structural_folds=['anchor'])
        return old, caller, owner, fold, row

    def test_structural_fold_preserves_counts_and_rejects_literal_or_occurrence_drift(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, caller, owner, fold, row = self.fixture(root)
            normalized = module.normalize_structural_folds(root, row, [fold], lambda *_: old)
            self.assertEqual(normalized, {'symbol:false': 2})
            for mutation in ('anchor = true', 'anchor = false; anchor = false', ''):
                (root / 'audio.swift').write_text(owner.replace('anchor = false', mutation))
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    module.normalize_structural_folds(root, row, [fold], lambda *_: old)
            (root / 'audio.swift').write_text('final class Audio {}\n' + owner.replace('class Audio', 'class Other'))
            with self.assertRaises(ValueError):
                module.normalize_structural_folds(root, row, [fold], lambda *_: old)

    def test_structural_fold_rejects_stale_missing_extra_and_invalid_mapping(self):
        import copy
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, caller, owner, fold, row = self.fixture(root)
            for mutation in (caller.replace('audio.resetAnchor()', '', 1),
                             caller.replace('audio.resetAnchor()', 'audio.resetAnchor(); audio.resetAnchor()', 1)):
                (root / 'session.swift').write_text(mutation)
                with self.assertRaises(ValueError):
                    module.normalize_structural_folds(root, row, [fold], lambda *_: old)
            (root / 'session.swift').write_text(caller)
            for change in ({'lifecycle_methods': ['stop', 'missing']}, {'before_count': 3},
                           {'before_sha256': 'stale'}, {'after_file': '../audio.swift'},
                           {'current_scope': ['session.swift']}, {'after_owner': 'Wrong'},
                           {'token': 'symbol:true'}, {'call': 'audio.other()'}):
                changed = copy.deepcopy(fold); changed.update(change)
                with self.subTest(change=change), self.assertRaises(ValueError):
                    module.normalize_structural_folds(root, row, [changed], lambda *_: old)
            with self.assertRaises(ValueError):
                module.normalize_structural_folds(root, row, [fold, fold], lambda *_: old)

if __name__ == '__main__':
    unittest.main()
