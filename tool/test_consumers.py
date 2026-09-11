import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ConsumerGateTests(unittest.TestCase):
    def test_lists_the_five_independent_build_cases(self):
        environment = dict(os.environ, YL_REPO_ROOT=str(ROOT))
        result = subprocess.run(
            ["sh", str(ROOT / "tool/check_consumers.sh"), "--list"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "android",
                "ios-cocoapods",
                "macos-cocoapods",
                "ios-swiftpm",
                "macos-swiftpm",
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
