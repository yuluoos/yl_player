#!/bin/sh
set -eu
YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)
: "${YL_ANDROID_DEVICE_ID:?Set YL_ANDROID_DEVICE_ID to the verified Android emulator/device ID}"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
if [ "${YL_ANDROID_SKIP_JVM:-0}" != "1" ]; then
  ./gradlew :yl_player_android:testDebugUnitTest --stacktrace
fi
cd "$YL_REPO_ROOT/packages/yl_player/example"
for suite in android_progressive_playback android_hls_playback android_session_replacement android_multi_player_rollback state_update_cadence; do
  sh "$YL_SCRIPT_DIR/run_android_integration.sh" "integration_test/${suite}_test.dart"
done
