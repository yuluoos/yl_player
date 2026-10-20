"""Default foundation must not require optional FFmpeg development packages."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


class DecodeProbeGateTests(unittest.TestCase):
    def load(self, enabled):
        spec = importlib.util.spec_from_file_location(
            'decode_probe_gate_fixture', Path(__file__).with_name('test_decode_probe.py'))
        module = importlib.util.module_from_spec(spec)
        environment = {'YL_RUN_DECODE_PROBE': '1'} if enabled else {}
        with patch.dict(os.environ, environment, clear=True), patch('shutil.which', return_value='/tool'):
            spec.loader.exec_module(module)
        return module.DecodeProbeTests

    def test_default_skips_even_when_runtime_tools_are_present(self):
        self.assertTrue(getattr(self.load(False), '__unittest_skip__', False))

    def test_explicit_opt_in_enables_actual_probe(self):
        self.assertFalse(getattr(self.load(True), '__unittest_skip__', False))
