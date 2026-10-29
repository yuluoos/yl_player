from pathlib import Path
p=Path('tool/test_android_scripts.py');s=p.read_text()
s=s.replace('        for name in ("check_native_android.sh",', '''        # These tests own their API/skip scenarios, regardless of caller stage flags.
        self.env.pop("YL_ANDROID_SKIP_JVM", None)
        self.env.pop("YL_ANDROID_API", None)
        for name in ("check_native_android.sh",''')
s=s.replace('        self.assertTrue(calls[0].startswith("JVM " + str(self.root)))\n        self.assertIn(":yl_player_android:testDebugUnitTest --stacktrace", calls[0])\n        suites = [line for line in calls if line.startswith("FLUTTER")]', '''        self.assertIn("build apk --debug --config-only --no-pub", calls[0])
        self.assertTrue(calls[1].startswith("JVM " + str(self.root)))
        self.assertIn(":yl_player_android:testDebugUnitTest --stacktrace", calls[1])
        suites = [line for line in calls if line.startswith("FLUTTER") and "--config-only" not in line]''')
i=s.index('    def test_explicit_shared_jvm_success_mode_skips_only_jvm')
s=s[:i]+'''    def test_fresh_checkout_prepares_wrapper_before_invoking_gradle(self):
        wrapper = self.root / "packages/yl_player_android/example/android/gradlew"
        template = self.root / "wrapper-template"
        shutil.copy(wrapper, template)
        wrapper.unlink()
        self.executable(self.bin / "flutter", \'\'\'echo "FLUTTER $*" >> "$CALL_LOG"
if [ "$*" = "build apk --debug --config-only --no-pub" ]; then
  cp "$TEST_ROOT/wrapper-template" "$TEST_ROOT/packages/yl_player_android/example/android/gradlew"
  chmod +x "$TEST_ROOT/packages/yl_player_android/example/android/gradlew"
fi\'\'\')
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(wrapper.exists())
        self.assertIn("JVM ", self.log.read_text())

    def test_configuration_failure_prevents_jvm_and_device_suites(self):
        self.executable(self.bin / "flutter", \'echo "FLUTTER $*" >> "$CALL_LOG"\\nexit 19\')
        result = self.run_gate()
        self.assertEqual(result.returncode, 19, result.stderr)
        calls = self.log.read_text()
        self.assertIn("--config-only", calls)
        self.assertNotIn("JVM ", calls)
        self.assertNotIn("integration_test/", calls)

'''+s[i:];p.write_text(s)
