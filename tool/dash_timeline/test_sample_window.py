import json
from pathlib import Path
import shutil, subprocess, sys, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
DASH = ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH'
class SampleWindowTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires Swift')
    def test_exact_sample_clipping(self):
        with tempfile.TemporaryDirectory(prefix='yl-dash-clipping-') as folder:
            out=Path(folder); main=out/'main.swift'
            main.write_bytes((Path(__file__).parent/'sample_window_tests.swift').read_bytes())
            source=[DASH/name for name in ['YlDashProgramTime.swift','YlDashProgramTimeline.swift','YlDashSampleWindow.swift']]
            build=subprocess.run(['xcrun','swiftc','-module-cache-path',str(out/'cache'),*map(str,source),str(main),'-o',str(out/'tests')],text=True,capture_output=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(out/'tests')],text=True,capture_output=True,timeout=15)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            rows=json.loads(run.stdout)
            self.assertTrue(all(r['passed'] for r in rows),[r for r in rows if not r['passed']])
            print(f'Exact sample window checks: {len(rows)}')
