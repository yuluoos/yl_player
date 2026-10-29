from pathlib import Path
p=Path('tool/check_player_v2.sh');s=p.read_text();old="  step 'android-jvm-unit'\n  run_in packages/yl_player_android/example/android"
assert old in s;s=s.replace(old,"  step 'android-jvm-unit'\n  # Fresh checkouts omit generated Gradle launchers and local SDK properties.\n  # Flutter prepares them without compiling an APK or changing pinned versions.\n  run_in packages/yl_player_android/example flutter build apk --debug --config-only --no-pub\n  run_in packages/yl_player_android/example/android");p.write_text(s)
p=Path('tool/check_native_android.sh');s=p.read_text();old='if [ "${YL_ANDROID_SKIP_JVM:-0}" != "1" ]; then\n  ./gradlew';assert old in s;s=s.replace(old,'if [ "${YL_ANDROID_SKIP_JVM:-0}" != "1" ]; then\n  (cd .. && "${YL_FLUTTER:-flutter}" build apk --debug --config-only --no-pub)\n  ./gradlew');p.write_text(s)
p=Path('packages/yl_player/example/integration_test/support/android_callback_probe.dart');s=p.read_text();s=s.replace('        final value = (message! as List<Object?>).single!;', '''        final arguments = message! as List<Object?>;
        final Object value = method == 'onNetworkBytesReceived'
            ? (arguments[0]! as String, arguments[1] as int?)
            : arguments.single!;''');s=s.replace("  static const methods = [\n", "  static const methods = [\n    'onNetworkBytesReceived',\n");p.write_text(s)
