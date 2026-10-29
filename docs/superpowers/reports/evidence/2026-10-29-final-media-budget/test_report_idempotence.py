from pathlib import Path
import subprocess,json,unittest
class ReportIdempotenceTests(unittest.TestCase):
 def test_repeated_generation_keeps_unique_bounded_references(self):
  report=Path('docs/superpowers/reports/2026-10-29-final-media-budget.md');ledger=Path('tool/release_readiness/inventory.json')
  command=['python3','/private/tmp/yl-final-media-budget/report.py']
  subprocess.run(command,check=True);first=(report.read_bytes(),ledger.read_bytes());subprocess.run(command,check=True)
  self.assertEqual(first,(report.read_bytes(),ledger.read_bytes()))
  rows=json.loads(ledger.read_text())['rows'];row=next(x for x in rows if x['requirement']=='CAP-ABR' and x['platform']=='ios')
  self.assertLessEqual(len(row['evidence']),20);self.assertEqual(len(row['evidence']),len(set(row['evidence'])))
if __name__=='__main__':unittest.main(verbosity=2)
