"""The compatibility adapter must keep every native architecture check."""
import unittest
from lipo_verify_compat import run


class LipoVerifyCompatibilityTests(unittest.TestCase):
    def test_multi_arch_checks_each_arch_with_native_lipo(self):
        calls = []
        self.assertEqual(run(['owned binary', '-verify_arch', 'arm64', 'x86_64'], lambda args: calls.append(args) or 0), 0)
        self.assertEqual(calls, [['/usr/bin/lipo', 'owned binary', '-verify_arch', 'arm64'], ['/usr/bin/lipo', 'owned binary', '-verify_arch', 'x86_64']])

    def test_missing_second_arch_is_failure(self):
        calls = []
        def native(args):
            calls.append(args)
            return 1 if args[-1] == 'x86_64' else 0
        self.assertEqual(run(['owned', '-verify_arch', 'arm64', 'x86_64'], native), 1)
        self.assertEqual(len(calls), 2)

    def test_first_failure_stops_and_preserves_exit_code(self):
        calls = []
        self.assertEqual(run(['owned', '-verify_arch', 'arm64', 'x86_64'], lambda args: calls.append(args) or 7), 7)
        self.assertEqual(len(calls), 1)

    def test_other_operations_are_passed_through_unchanged(self):
        for args in [['owned', '-verify_arch', 'arm64'], ['-output', 'owned', '-extract', 'arm64', '-extract', 'x86_64', 'owned'], ['-archs', 'owned']]:
            calls = []
            self.assertEqual(run(args, lambda value: calls.append(value) or 3), 3)
            self.assertEqual(calls, [['/usr/bin/lipo', *args]])


if __name__ == '__main__':
    unittest.main()
