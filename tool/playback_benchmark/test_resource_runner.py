from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from run_resources import run_logged


class RunnerTests(unittest.TestCase):
    def test_timeout_retains_output_and_stops_owned_command(self):
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'log'
            with self.assertRaises(subprocess.TimeoutExpired):
                run_logged([sys.executable,'-c','import time;print("observed",flush=True);time.sleep(30)'],
                           Path(directory),log,0.25)
            self.assertIn('observed',log.read_text())

    def test_nonzero_exit_is_returned_with_raw_output(self):
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'log'
            code=run_logged([sys.executable,'-c','print("failed");raise SystemExit(3)'],Path(directory),log,5)
            self.assertEqual(code,3);self.assertIn('failed',log.read_text())

if __name__=='__main__':unittest.main()
