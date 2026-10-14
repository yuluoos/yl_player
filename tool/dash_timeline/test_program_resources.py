"""Exercise production MPD parsing against owned, independently pinned media."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'

class ProgramResourceTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS Swift toolchain')
    def test_managed_program_resources(self):
        with tempfile.TemporaryDirectory(prefix='yl-dash-program-') as directory:
            out = Path(directory)
            main = out/'main.swift'
            main.write_bytes((Path(__file__).parent/'program_resource_tests.swift').read_bytes())
            sources = [SHARED/'DASH'/name for name in ['YlDashDocument.swift', 'YlDashSidx.swift', 'YlDashProgramTime.swift', 'YlDashProgramTimeline.swift', 'YlDashProgramDocument.swift', 'YlDashProgramResources.swift']]
            sources += [SHARED/'Dependencies/YlOpenCancellationToken.swift', SHARED/'Dependencies/YlNetworkConfiguration.swift', SHARED/'Network/YlManagedRequestPolicy.swift', SHARED/'Network/YlOriginCredentialPolicy.swift', Path(__file__).parent/'program_resource_support.swift']
            build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(out/'cache'), *map(str, sources), str(main), '-o', str(out/'tests')], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout+build.stderr)
            run = subprocess.run([str(out/'tests'), str(ROOT/'packages/yl_player/example/assets/test_media/dash_timeline')], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
            rows = json.loads(run.stdout)
            self.assertGreaterEqual(len(rows), 15)
            self.assertEqual(len({r['name'] for r in rows}), len(rows))
            self.assertTrue(all(r['passed'] for r in rows), [r for r in rows if not r['passed']])
            print(f'Swift resource checks: {len(rows)}')
if __name__ == '__main__': unittest.main()
