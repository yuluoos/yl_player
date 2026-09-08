"""The audit must reject unreviewed numeric and enum behavior changes."""
import importlib.util
from pathlib import Path
import unittest

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

if __name__ == '__main__':
    unittest.main()
