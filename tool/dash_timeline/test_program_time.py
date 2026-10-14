"""Run the production Swift rational program clock without Flutter/Xcode UI."""
from fractions import Fraction
import random
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DASH = ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH'

class ProgramTimeTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS Swift toolchain')
    def test_production_program_time(self):
        with tempfile.TemporaryDirectory(prefix='yl-dash-clock-') as directory:
            out = Path(directory)
            main = out/'main.swift'
            main.write_bytes((Path(__file__).parent/'program_time_tests.swift').read_bytes())
            sources = [DASH/'YlDashProgramTime.swift', DASH/'YlDashProgramTimeline.swift']
            build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(out/'cache'),
                *map(str, sources), str(main), '-o', str(out/'tests')], capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout+build.stderr)
            rng = random.Random(1013)
            edges = [-(2**63), -(2**63)+1, -1, 0, 1, 2**63-2, 2**63-1]
            pairs = [(a, d, b, e) for a in edges for b in edges for d, e in [(1, 1), (2**63-1, 2**63-2)]]
            pairs += [(rng.randrange(-(2**63), 2**63), rng.randrange(1, 2**63), rng.randrange(-(2**63), 2**63), rng.randrange(1, 2**63)) for _ in range(400)]
            cases = []
            for a, d, b, e in pairs:
                x, y = Fraction(a, d), Fraction(b, e)
                for op, result in [('add', x+y), ('subtract', x-y)]:
                    valid = -(2**63) <= result.numerator < 2**63 and result.denominator < 2**63
                    cases.append(dict(a=str(a), d=str(d), b=str(b), e=str(e), op=op,
                        n=str(result.numerator) if valid else None, q=str(result.denominator) if valid else None))
                cases.append(dict(a=str(a), d=str(d), b=str(b), e=str(e), op='less', expected=x<y))
            run = subprocess.run([str(out/'tests')], input=json.dumps(cases), capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
            rows = json.loads(run.stdout)
            print(f'Swift program checks: {len(rows)} (independent Fraction cases: {len(cases)})')
            self.assertGreaterEqual(len(rows), 16)
            self.assertEqual(len({r['name'] for r in rows}), len(rows))
            self.assertTrue(all(r['passed'] for r in rows), [r for r in rows if not r['passed']])

if __name__ == '__main__': unittest.main()
