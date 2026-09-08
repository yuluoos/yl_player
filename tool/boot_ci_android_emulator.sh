#!/bin/sh
set -eu
YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
: "${YL_ANDROID_API:?Set YL_ANDROID_API to 24 or 36}"
case "$YL_ANDROID_API" in 24|36) ;; *) echo 'Supported required APIs: 24, 36' >&2; exit 2;; esac
: "${ANDROID_HOME:?Set ANDROID_HOME to an installed Android SDK}"
YL_ANDROID_ABI=${YL_ANDROID_ABI:-x86_64}
YL_ANDROID_PORT=${YL_ANDROID_PORT:-5580}
YL_ANDROID_RUNTIME=$(mktemp -d "${TMPDIR:-/tmp}/yl-android-api${YL_ANDROID_API}.XXXXXX")
export ANDROID_USER_HOME="$YL_ANDROID_RUNTIME/user"
export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
mkdir -p "$ANDROID_AVD_HOME"
YL_ANDROID_AVD="yl_ci_api${YL_ANDROID_API}_$$"
YL_ANDROID_IMAGE="system-images;android-${YL_ANDROID_API};google_apis;${YL_ANDROID_ABI}"
YL_ADB="$ANDROID_HOME/platform-tools/adb"
YL_SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
YL_AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
"$YL_SDKMANAGER" "$YL_ANDROID_IMAGE" >&2
printf 'no\n' | "$YL_AVDMANAGER" create avd -n "$YL_ANDROID_AVD" -k "$YL_ANDROID_IMAGE" --device pixel_2 >&2
YL_DEVICE_ID="emulator-$YL_ANDROID_PORT"
if "$YL_ADB" devices | awk 'NR > 1 {print $1}' | grep -qx "$YL_DEVICE_ID"; then
  echo "Port already owned by another emulator: $YL_DEVICE_ID" >&2; exit 2
fi
"$ANDROID_HOME/emulator/emulator" -avd "$YL_ANDROID_AVD" -port "$YL_ANDROID_PORT" \
  -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
  > "$YL_ANDROID_RUNTIME/emulator.log" 2>&1 &
YL_EMULATOR_PID=$!
trap 'kill "$YL_EMULATOR_PID" 2>/dev/null || true' EXIT HUP INT TERM
echo "Android runtime: $YL_ANDROID_RUNTIME; AVD: $YL_ANDROID_AVD; pid: $YL_EMULATOR_PID" >&2
YL_ATTEMPT=0
while [ "$("$YL_ADB" -s "$YL_DEVICE_ID" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; do
  YL_ATTEMPT=$((YL_ATTEMPT + 1))
  if [ "$YL_ATTEMPT" -ge 180 ] || ! kill -0 "$YL_EMULATOR_PID" 2>/dev/null; then
    cat "$YL_ANDROID_RUNTIME/emulator.log" >&2
    kill "$YL_EMULATOR_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
[ "$("$YL_ADB" -s "$YL_DEVICE_ID" emu avd name | tr -d '\r' | head -n 1)" = "$YL_ANDROID_AVD" ]
[ "$("$YL_ADB" -s "$YL_DEVICE_ID" shell getprop ro.build.version.sdk | tr -d '\r')" = "$YL_ANDROID_API" ]
for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$YL_ADB" -s "$YL_DEVICE_ID" shell settings put global "$setting" 0 >&2
done
trap - EXIT HUP INT TERM
printf '%s\n' "$YL_DEVICE_ID"
