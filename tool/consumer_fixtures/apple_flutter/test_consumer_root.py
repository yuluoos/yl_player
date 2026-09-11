"""Portable entry-point contract: a caller cannot redirect the active checkout."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]


class ConsumerRootTest(unittest.TestCase):
    def test_accepts_captured_root_from_outside_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, YL_REPO_ROOT=str(REPO),
                               YL_APPLE_CONSUMERS=str(Path(temporary) / "consumers"),
                               YL_FLUTTER="unused-for-help")
            for name in ["bootstrap_apple_consumers.sh", "check_apple_consumer.sh"]:
                result = subprocess.run(["sh", str(REPO / "tool" / name), "--help"],
                                        cwd=temporary, env=environment,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--manager", result.stdout)

    def test_rejects_foreign_root_before_generating_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, YL_REPO_ROOT=temporary)
            for name in ["bootstrap_apple_consumers.sh", "check_apple_consumer.sh"]:
                with self.subTest(entry_point=name):
                    result = subprocess.run(["sh", str(REPO / "tool" / name), "--help"],
                                            cwd=temporary, env=environment,
                                            text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("YL_REPO_ROOT must identify this script's active checkout", result.stderr)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_warm_shared_package_cache_does_not_claim_a_fresh_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            consumers = base / "consumers"
            cache = base / "package-cache"
            cache.mkdir()
            (cache / "warm-marker").write_text("preserved\n")
            environment = dict(
                os.environ,
                YL_REPO_ROOT=str(REPO),
                YL_APPLE_CONSUMERS=str(consumers),
                YL_APPLE_PACKAGE_CACHE_ROOT=str(cache),
                YL_FLUTTER="unused-for-help",
            )

            result = subprocess.run(
                ["sh", str(REPO / "tool/check_apple_consumer.sh"), "--help"],
                cwd=temporary,
                env=environment,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((cache / "warm-marker").read_text(), "preserved\n")
            self.assertTrue((cache / "source-packages").is_dir())
            self.assertTrue((cache / "package-cache").is_dir())
            self.assertEqual(list(consumers.glob("*-link")), [])


if __name__ == "__main__":
    unittest.main()
