"""Exercise bounded production readiness evidence with controlled timestamps."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ReadinessTraceTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS Swift toolchain')
    def test_readiness_boundaries_and_bounded_retention(self):
        root = Path(__file__).resolve().parents[2]
        source = root/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Clock/YlTimedVideoReadinessTrace.swift'
        with tempfile.TemporaryDirectory(prefix='yl-ready-tests-') as directory:
            out = Path(directory)
            binary = out/'tests'
            build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(out/'cache'),
                str(source), str(Path(__file__).with_name('readiness_trace_tests.swift')), '-o', str(binary)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__': unittest.main()
