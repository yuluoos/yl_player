"""Compile the tool-only scheduler; never replaces the production audio driver."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class AudioBoundaryPrototypeTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS Swift toolchain')
    def test_bounded_terminal_scheduler(self):
        source = Path(__file__).parent
        with tempfile.TemporaryDirectory(prefix='yl-boundary-tests-') as directory:
            out = Path(directory)
            main = out/'main.swift'
            main.write_bytes((source/'audio_boundary_tests.swift').read_bytes())
            binary = out/'tests'
            build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(out/'cache'),
                str(source/'AudioBoundaryPrototype.swift'), str(main), '-o', str(binary)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout+build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
            results = json.loads(run.stdout)
            self.assertEqual(len(results), 12)
            self.assertEqual(len({r['name'] for r in results}), 12)
            self.assertTrue(all(r['passed'] for r in results), results)


if __name__ == '__main__': unittest.main()
