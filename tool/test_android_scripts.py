"""Hermetic shell gate contracts; no SDK, Gradle, Flutter or emulator runs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class AndroidScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yl-android-script-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "checkout with spaces"
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        (self.root / "tool").mkdir(parents=True)
        (self.root / "packages/yl_player/example").mkdir(parents=True)
        (self.root / "packages/yl_player_android/example/android").mkdir(parents=True)
        self.log = Path(self.temp.name) / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_ROOT=str(self.root), CALL_LOG=str(self.log), TMPDIR=self.temp.name,
                        YL_ANDROID_DEVICE_ID="emulator-5580")
        for name in ("check_native_android.sh", "run_android_integration.sh",
                     "boot_ci_android_emulator.sh"):
            shutil.copy(SCRIPTS / name, self.root / "tool" / name)
        self.executable(self.bin / "git", 'test "$1" = -C\ntest "$2" = "$TEST_ROOT/tool"\nprintf "%s\\n" "$TEST_ROOT"')
        self.executable(self.root / "packages/yl_player_android/example/android/gradlew",
                        'printf "JVM %s %s\\n" "$PWD" "$*" >> "$CALL_LOG"')
        self.executable(self.bin / "flutter", 'printf "FLUTTER %s %s\\n" "$PWD" "$*" >> "$CALL_LOG"')
        self.executable(self.bin / "adb", '''printf 'ADB %s\n' "$*" >> "$CALL_LOG"
case "$*" in *getprop*) echo 24;; esac''')

    def executable(self, path, body):
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_gate(self, skip=None):
        if skip is not None:
            self.env["YL_ANDROID_SKIP_JVM"] = skip
        return subprocess.run(["sh", str(self.root / "tool/check_native_android.sh")],
                              cwd="/", env=self.env, capture_output=True, text=True, timeout=20)

    def test_standalone_is_rooted_and_runs_qualified_jvm_then_five_suites(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertTrue(calls[0].startswith("JVM " + str(self.root)))
        self.assertIn(":yl_player_android:testDebugUnitTest --stacktrace", calls[0])
        suites = [line for line in calls if line.startswith("FLUTTER")]
        self.assertEqual(len(suites), 5)
        names = (
            "android_progressive_playback",
            "android_hls_playback",
            "android_session_replacement",
            "android_multi_player_rollback",
            "state_update_cadence",
        )
        for name, line in zip(names, suites):
            self.assertIn(f"integration_test/{name}_test.dart", line)
            self.assertIn("--dart-define=YL_ANDROID_API=24", line)
            self.assertIn(str(self.root / "packages/yl_player/example"), line)

    def test_explicit_shared_jvm_success_mode_skips_only_jvm(self):
        result = self.run_gate("1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertNotIn("JVM ", calls)
        self.assertEqual(calls.count("FLUTTER "), 5)

    def test_failure_stops_later_suites(self):
        self.executable(self.bin / "flutter", 'echo FLUTTER >> "$CALL_LOG"\nexit 17')
        result = self.run_gate("1")
        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.log.read_text().count("FLUTTER"), 1)

    def test_missing_device_and_unsupported_api_fail_before_tools(self):
        self.env.pop("YL_ANDROID_DEVICE_ID")
        self.assertNotEqual(self.run_gate().returncode, 0)
        self.env["YL_ANDROID_API"] = "37"
        result = subprocess.run(["sh", str(self.root / "tool/boot_ci_android_emulator.sh")],
                                cwd="/", env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.log.exists())

    def test_boot_isolated_api24_outputs_only_verified_device(self):
        sdk = Path(self.temp.name) / "sdk"
        for subdir in ("cmdline-tools/latest/bin", "platform-tools", "emulator"):
            (sdk / subdir).mkdir(parents=True)
        self.env.update(ANDROID_HOME=str(sdk), YL_ANDROID_API="24")
        self.executable(sdk / "cmdline-tools/latest/bin/sdkmanager", 'echo "$*" >> "$CALL_LOG"')
        self.executable(sdk / "cmdline-tools/latest/bin/avdmanager",
                        'while [ "$1" != -n ]; do shift; done\nshift\necho "$1" > "$TEST_ROOT/avd-name"')
        self.executable(sdk / "platform-tools/adb", '''echo "ADB $*" >> "$CALL_LOG"
case "$*" in
  *sys.boot_completed*) echo 1;;
  *ro.build.version.sdk*) echo 24;;
  *"emu avd name"*) cat "$TEST_ROOT/avd-name"; echo OK;;
  devices) echo 'List of devices attached';;
esac''')
        self.executable(sdk / "emulator/emulator", 'echo $$ > "$TEST_ROOT/emulator-pid"\nexec sleep 10')
        try:
            result = subprocess.run(["sh", str(self.root / "tool/boot_ci_android_emulator.sh")],
                                    cwd="/", env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "emulator-5580\n")
            self.assertIn("system-images;android-24;google_apis;x86_64", self.log.read_text())
            self.assertEqual(self.log.read_text().count("settings put global"), 3)
        finally:
            pid = self.root / "emulator-pid"
            if pid.exists():
                try:
                    os.kill(int(pid.read_text()), 15)
                except ProcessLookupError:
                    pass

    def test_actual_lifecycle_choreography_is_marker_bound(self):
        self.executable(self.bin / "flutter", '''echo YL_ANDROID_LIFECYCLE_BACKGROUND_READY
sleep 2
echo YL_ANDROID_LIFECYCLE_FOREGROUND_READY
sleep 2''')
        result = subprocess.run(["sh", str(self.root / "tool/run_android_integration.sh"), "suite.dart"],
                                cwd="/", env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertEqual(calls.count("input keyevent KEYCODE_HOME"), 1)
        self.assertEqual(calls.count("shell am start -n dev.ylplayer.yl_player_example/"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
