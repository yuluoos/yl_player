"""Opt-in real GPU test discovery; lack of a native context is a skip, never a pass."""
import os
from pathlib import Path
import subprocess
import unittest


class CglProbeTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('YL_DOLBY_CGL_PROBE_ROOT'),
                         'requires pinned Task1B1 build and macOS GPU access')
    def test_pinned_upstream_gpu_assertions_on_native_context(self):
        root = Path(os.environ['YL_DOLBY_CGL_PROBE_ROOT']).resolve()
        self.assertTrue(root.is_dir(), 'configured probe directory does not exist')
        runner = Path(__file__).resolve().parent / 'probes/run_cgl_tests.sh'
        log = root / 'cgl-discovery.log'
        with log.open('w') as output:
            result = subprocess.run(['bash', str(runner), str(root)],
                                    stdout=output, stderr=subprocess.STDOUT,
                                    timeout=120, check=False)
        if result.returncode == 77:
            self.skipTest(f'native context or required GPU capability unavailable; {log}')
        self.assertEqual(result.returncode, 0, f'CGL probe failed; inspect {log}')


if __name__ == '__main__':
    unittest.main()
