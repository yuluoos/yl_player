"""Execute production metadata and public error checks without test devices."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Apple Swift checks require macOS')
class FELAdmissionTests(unittest.TestCase):
    def test_pairing_and_metadata_admission(self):
        result = subprocess.run(['sh', str(ROOT / 'tool/apple_fel/run_tests.sh')],
                                capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_public_failure_envelopes(self):
        result = subprocess.run([sys.executable, str(ROOT / 'tool/apple_fel/run_failure_tests.py')],
                                capture_output=True, text=True, timeout=240)
        if result.returncode == 77:
            self.skipTest(result.stdout.strip())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
