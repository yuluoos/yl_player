#!/bin/sh
# Internal runner: bounded host-side real Activity lifecycle orchestration.
set -eu
YL_SUITE=$1
: "${YL_ANDROID_DEVICE_ID:?}"
YL_ADB=${YL_ADB:-adb}
YL_ANDROID_API=$("$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" shell getprop ro.build.version.sdk | tr -d '\r')
YL_RUN_LOG=$(mktemp "${TMPDIR:-/tmp}/yl-android-test.XXXXXX")
YL_COMPONENT=dev.ylplayer.yl_player_example/dev.ylplayer.yl_player_example.MainActivity
YL_BACKGROUND=0
YL_FOREGROUND=0
YL_TEST_PID=
cleanup() {
  if [ "$YL_BACKGROUND" = 1 ] && [ "$YL_FOREGROUND" = 0 ]; then
    "$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" shell am start -n "$YL_COMPONENT" >&2 || true
  fi
  if [ -n "$YL_TEST_PID" ]; then kill "$YL_TEST_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT HUP INT TERM
# API24 logcat can replay a former VM-service address to Flutter. Preserve the
# prior buffer, then clear this explicitly selected test device before launch.
"$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" logcat -d > "$YL_RUN_LOG.previous-logcat"
"$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" logcat -c
flutter test "$YL_SUITE" -d "$YL_ANDROID_DEVICE_ID" --timeout 5m \
  --dart-define="YL_ANDROID_API=$YL_ANDROID_API" > "$YL_RUN_LOG" 2>&1 &
YL_TEST_PID=$!
YL_SECONDS=0
while kill -0 "$YL_TEST_PID" 2>/dev/null; do
  if [ "$YL_BACKGROUND" = 0 ] && grep -q 'YL_ANDROID_LIFECYCLE_BACKGROUND_READY' "$YL_RUN_LOG"; then
    "$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" shell input keyevent KEYCODE_HOME >&2
    YL_BACKGROUND=1
  fi
  if [ "$YL_BACKGROUND" = 1 ] && [ "$YL_FOREGROUND" = 0 ] && grep -q 'YL_ANDROID_LIFECYCLE_FOREGROUND_READY' "$YL_RUN_LOG"; then
    "$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" shell am start -n "$YL_COMPONENT" >&2
    YL_FOREGROUND=1
  fi
  if [ "$YL_SECONDS" -ge 600 ]; then
    cat "$YL_RUN_LOG"
    echo "Android test deadline exceeded; log: $YL_RUN_LOG" >&2
    exit 1
  fi
  sleep 1
  YL_SECONDS=$((YL_SECONDS + 1))
done
YL_RESULT=0
wait "$YL_TEST_PID" || YL_RESULT=$?
YL_TEST_PID=
cat "$YL_RUN_LOG"
echo "Android test log: $YL_RUN_LOG" >&2
if [ "$YL_RESULT" != 0 ]; then
  "$YL_ADB" -s "$YL_ANDROID_DEVICE_ID" logcat -d > "$YL_RUN_LOG.failure-logcat"
fi
exit "$YL_RESULT"
