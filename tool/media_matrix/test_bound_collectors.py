"""Extraction failures are retained as failed evidence, not parser crashes."""
import unittest
from run_bound_android import parse_rows

class CollectorTest(unittest.TestCase):
    def test_missing_or_malformed_native_records_fail_closed(self):
        for raw in [b'cat: files/missing: No such file or directory\n',b'{}\nBROKEN\n',b'[]\n',b'']:
            rows,valid=parse_rows(raw)
            self.assertFalse(valid)
    def test_json_lines_retained(self):
        rows,valid=parse_rows(b'{"caseId":"one"}\n{"caseId":"two"}\n')
        self.assertTrue(valid);self.assertEqual(['one','two'],[r['caseId'] for r in rows])

if __name__=='__main__':unittest.main()
