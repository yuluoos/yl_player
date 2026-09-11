#!/usr/bin/env python3

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tool/check_player_v2.sh"


def run_gate(*arguments: str, **environment: str) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, YL_GATE_TEST_MODE="1", **environment)
    return subprocess.run(
        ["sh", str(SCRIPT), *arguments],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


class PlayerV2GateTest(unittest.TestCase):
    def test_full_diagnostic_preserves_order_and_never_claims_release_pass(self) -> None:
        result = run_gate("--full", "--no-device")
        self.assertEqual(result.returncode, 0, result.stdout)
        expected = [
            "01-pigeon-drift",
            "02-combined-ffmpeg-artifact-contract",
            "03-foundation",
            "android-jvm-unit",
            "06-macos-native-universal-rosetta-integration",
            "07-consumer-fixtures",
            "08-public-surface",
            "09-publication-dry-run",
            "10-format-analyze-diff-check",
        ]
        positions = [result.stdout.index(f"PLAYER_V2_STEP {name}") for name in expected]
        self.assertEqual(positions, sorted(positions), result.stdout)
        self.assertIn("UNVERIFIED_REQUIRED Android API 24", result.stdout)
        self.assertIn("UNVERIFIED_REQUIRED Android API 36", result.stdout)
        self.assertIn("UNVERIFIED_REQUIRED iOS Simulator", result.stdout)
        self.assertIn("release_evidence=false", result.stdout)
        self.assertNotIn("PLAYER_V2_FULL_PASS", result.stdout)

    def test_invalid_base_fails_closed_to_all_native_units(self) -> None:
        result = run_gate("--quick", YL_BASE_REF="not-a-revision")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("reason=missing-or-invalid-YL_BASE_REF", result.stdout)
        self.assertIn("PLAYER_V2_STEP android-jvm-unit", result.stdout)
        self.assertIn("PLAYER_V2_STEP apple-ios-native-unit", result.stdout)
        self.assertIn("PLAYER_V2_STEP apple-macos-native-unit", result.stdout)

    def test_unrelated_docs_do_not_select_native_units(self) -> None:
        result = run_gate(
            "--quick", YL_GATE_CHANGED_PATHS_OVERRIDE="docs/release-notes.md"
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("UNAFFECTED android-jvm-unit", result.stdout)
        self.assertIn("UNAFFECTED apple-native-unit", result.stdout)
        self.assertNotIn("PLAYER_V2_STEP android-jvm-unit", result.stdout)
        self.assertNotIn("PLAYER_V2_STEP apple-ios-native-unit", result.stdout)

    def test_ci_stage_is_labeled_as_a_shard(self) -> None:
        result = run_gate("--quick", "--stage", "common")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("release_evidence=false", result.stdout)
        self.assertNotIn("CI_SHARD_ONLY", result.stdout)
        self.assertNotIn("PLAYER_V2_QUICK_PASS", result.stdout)

    def test_staged_only_android_path_selects_android_unit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="yl-player-gate-test-") as root:
            checkout = Path(root)
            (checkout / "tool").mkdir()
            shutil.copy2(SCRIPT, checkout / "tool/check_player_v2.sh")
            subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
            subprocess.run(
                ["git", "config", "user.email", "gate@example.invalid"],
                cwd=checkout,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Gate Test"],
                cwd=checkout,
                check=True,
            )
            subprocess.run(["git", "add", "tool/check_player_v2.sh"], cwd=checkout, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=checkout, check=True)
            staged = checkout / "packages/yl_player_android/staged.txt"
            staged.parent.mkdir(parents=True)
            staged.write_text("staged only\n")
            subprocess.run(["git", "add", str(staged)], cwd=checkout, check=True)
            result = subprocess.run(
                [
                    "sh",
                    str(checkout / "tool/check_player_v2.sh"),
                    "--quick",
                    "--stage",
                    "android-unit",
                ],
                cwd=checkout,
                env=dict(os.environ, YL_GATE_TEST_MODE="1", YL_BASE_REF="HEAD"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("PLAYER_V2_STEP android-jvm-unit", result.stdout)
            self.assertNotIn("UNAFFECTED android-jvm-unit", result.stdout)

    def test_full_aggregation_rejects_a_skipped_required_stage(self) -> None:
        result = run_gate(
            "--aggregate-full",
            YL_RESULT_FOUNDATION="success",
            YL_RESULT_ANDROID_UNIT="success",
            YL_RESULT_ANDROID_INTEGRATION="success",
            YL_RESULT_IOS="success",
            YL_RESULT_MACOS="success",
            YL_RESULT_ANDROID_CONSUMER="success",
            YL_RESULT_APPLE_CONSUMERS="success",
            YL_RESULT_REPRODUCIBILITY="skipped",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Required ffmpeg-reproducibility result was skipped", result.stdout)
        self.assertNotIn("AGGREGATE_PASS", result.stdout)

    def test_quick_aggregation_requires_every_selected_apple_stage(self) -> None:
        result = run_gate(
            "--aggregate-quick",
            YL_RESULT_FOUNDATION="success",
            YL_SELECTED_APPLE="true",
            YL_RESULT_APPLE_UNIT="success",
            YL_RESULT_IOS="skipped",
            YL_RESULT_MACOS="success",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Required ios-integration result was skipped", result.stdout)
        self.assertNotIn("AGGREGATE_PASS", result.stdout)

    def test_test_mode_never_emits_aggregate_release_pass(self) -> None:
        result = run_gate(
            "--aggregate-quick",
            YL_RESULT_FOUNDATION="success",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("release_evidence=false", result.stdout)
        self.assertNotIn("AGGREGATE_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
