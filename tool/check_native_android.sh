#!/bin/sh
set -eu
YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)
: "${YL_ANDROID_DEVICE_ID:?Set YL_ANDROID_DEVICE_ID to the verified Android emulator/device ID}"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
if [ "${YL_ANDROID_SKIP_JVM:-0}" != "1" ]; then
  (cd .. && "${YL_FLUTTER:-flutter}" build apk --debug --config-only --no-pub)
  ./gradlew :yl_player_android:testDebugUnitTest --stacktrace
fi
# Flutter resolves adb inside ANDROID_HOME. On the hosted Android 7 emulator,
# streaming the APK into Package Manager can stall until the suite deadline.
# Give Flutter a private SDK view for this job and stage the exact APK first.
if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "${YL_ANDROID_API:-}" = 24 ]; then
  sdk=$(mktemp -d "${RUNNER_TEMP:?}/yl-api24-sdk.XXXXXX")
  mkdir "$sdk/platform-tools"
  for entry in "${ANDROID_HOME:?}"/*; do
    [ "$entry" = "$ANDROID_HOME/platform-tools" ] || ln -s "$entry" "$sdk/"
  done
  for entry in "$ANDROID_HOME"/platform-tools/*; do
    [ "$entry" = "$ANDROID_HOME/platform-tools/adb" ] || ln -s "$entry" "$sdk/platform-tools/"
  done
  export YL_HOST_ADB="$ANDROID_HOME/platform-tools/adb"
  cat > "$sdk/platform-tools/adb" <<'ADB'
#!/bin/sh
set -eu
if [ "${1:-}" = -s ] && [ "${2:-}" = "$YL_ANDROID_DEVICE_ID" ] && [ "${3:-}" = install ]; then
  shift 3
  exec "$YL_HOST_ADB" -s "$YL_ANDROID_DEVICE_ID" install --no-streaming "$@"
fi
exec "$YL_HOST_ADB" "$@"
ADB
  chmod +x "$sdk/platform-tools/adb"
  export ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk"
fi
cd "$YL_REPO_ROOT/packages/yl_player/example"
set --
for suite in android_progressive_playback android_hls_playback android_session_replacement android_multi_player_rollback state_update_cadence; do
  set -- "$@" "integration_test/${suite}_test.dart"
done
if [ "${YL_ANDROID_API:-}" = 24 ]; then
  if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
    mkdir -p "$YL_REPO_ROOT/android-failure"
    export YL_ANDROID_REPORT_ROOT="$YL_REPO_ROOT/android-failure"
  fi
  if [ -n "${YL_ANDROID_TEST_TARGET:-}" ]; then
    # Keep the device receipt alongside this run's Flutter reports.
    YL_ANDROID_REPORT_ROOT=${YL_ANDROID_REPORT_ROOT:-$(mktemp -d)}
    export YL_ANDROID_REPORT_ROOT
    python3 -B "$YL_SCRIPT_DIR/ci_playback_shards.py" verify-android "$YL_ANDROID_TEST_TARGET" "$YL_ANDROID_DEVICE_ID" --evidence "$YL_ANDROID_REPORT_ROOT"
  fi
  exec sh "$YL_SCRIPT_DIR/run_android_integration.sh" --all-suites "$@"
fi
for suite do
  sh "$YL_SCRIPT_DIR/run_android_integration.sh" "$suite"
done
