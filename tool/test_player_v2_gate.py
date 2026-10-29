#!/usr/bin/env python3

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
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

    def test_root_dependency_files_select_both_native_unit_shards(self) -> None:
        for path in ("pubspec.lock", "pubspec.yaml"):
            for stage, marker in (("android-unit", "android-jvm-unit"),
                                  ("apple-unit", "apple-ios-native-unit")):
                with self.subTest(path=path, stage=stage):
                    result = run_gate("--quick", "--stage", stage,
                                      YL_GATE_CHANGED_PATHS_OVERRIDE=path)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertIn("PLAYER_V2_STEP " + marker, result.stdout)

    def test_actual_workflow_selects_native_and_consumers_for_root_dependencies(self) -> None:
        # Execute the real workflow selection shell against real Git changes;
        # asserting only its regex text would miss broken branching or outputs.
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        selection = workflow.split("      - id: select\n", 1)[1].split("\n  foundation:", 1)[0]
        shell = textwrap.dedent(selection.split("        run: |\n", 1)[1])
        cases = (("pubspec.lock", "true"), ("pubspec.yaml", "true"),
                 ("docs/release-notes.md", "false"))
        for path, expected in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory(prefix="yl-ci-select-") as temp:
                checkout = Path(temp)
                def git(*args):
                    return subprocess.check_output(["git", *args], cwd=checkout, text=True).strip()
                git("init", "-q")
                git("config", "user.email", "gate@example.invalid")
                git("config", "user.name", "Gate Test")
                (checkout / "base").write_text("base\n")
                git("add", ".")
                git("commit", "-qm", "base")
                base = git("rev-parse", "HEAD")
                target = checkout / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("dependency update\n")
                git("add", ".")
                git("commit", "-qm", "change")
                output = checkout / "outputs"
                result = subprocess.run(["sh", "-eu", "-c", shell], cwd=checkout,
                    env=dict(os.environ, EVENT_NAME="push", EVENT_BASE=base, GITHUB_OUTPUT=str(output)),
                    text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual({key: values[key] for key in ("android", "apple", "consumers")},
                                 {key: expected for key in ("android", "apple", "consumers")})
                self.assertEqual(values["artifact"], "false")

    def test_android_shard_configures_fresh_checkout_before_jvm_without_apk_build(self) -> None:
        result = run_gate("--quick", "--stage", "android-unit",
                          YL_GATE_CHANGED_PATHS_OVERRIDE="pubspec.lock")
        self.assertEqual(result.returncode, 0, result.stdout)
        prepare = "WOULD_RUN_IN packages/yl_player_android/example flutter build apk --debug --config-only --no-pub"
        jvm = "WOULD_RUN_IN packages/yl_player_android/example/android ./gradlew"
        self.assertIn(prepare, result.stdout)
        self.assertLess(result.stdout.index(prepare), result.stdout.index(jvm))

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
