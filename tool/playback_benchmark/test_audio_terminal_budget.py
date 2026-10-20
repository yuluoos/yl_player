import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules


class TerminalBudgetTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS Swift toolchain')
    def test_actual_ledger_and_terminal_model(self):
        source=Path(__file__).parent
        with tempfile.TemporaryDirectory(prefix='yl-terminal-tests-') as directory:
            out=Path(directory);main=out/'main.swift';main.write_bytes((source/'audio_terminal_tests.swift').read_bytes())
            native = build_modules(out/'native', include_delivery=False)
            native.compile_test([main, source/'AudioTerminalBudgetPrototype.swift'], out/'tests',
                                imports=['yl_player_media_core'])
            run=subprocess.run([str(out/'tests')],capture_output=True,text=True,timeout=15)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            rows=json.loads(run.stdout)
            self.assertEqual(len(rows),14)
            self.assertEqual(len({r['name'] for r in rows}),14)
            self.assertTrue(all(r['passed'] for r in rows),rows)


if __name__=='__main__': unittest.main()
