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

if __name__ == '__main__':
    unittest.main()
