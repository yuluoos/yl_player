#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
simulator_id=${YL_IOS_SIMULATOR_ID:-}

if [ -z "$simulator_id" ]; then
  simulator_id=$(
    xcrun simctl list devices booted |
      sed -n 's/.*(\([0-9A-F-][0-9A-F-]*\)) (Booted).*/\1/p' |
      head -n 1
  )
fi

if [ -z "$simulator_id" ]; then
  echo "Boot an iOS Simulator or set YL_IOS_SIMULATOR_ID." >&2
  exit 1
fi

# Integration tests replace Flutter's generated Dart entrypoint with a
# temporary listener. Restore the normal example configuration before invoking
# Xcode directly so a previous test run cannot poison the native test build.
(
  cd "$repo_root/packages/yl_player/example"
  flutter build ios --simulator --debug --config-only
)

xcodebuild test -quiet \
  -workspace "$repo_root/packages/yl_player/example/ios/Runner.xcworkspace" \
  -scheme Runner \
  -destination "platform=iOS Simulator,id=$simulator_id"

# xcodebuild can shut down the source simulator after running tests on a clone.
# Restore it before Flutter tries to discover the requested device.
if ! xcrun simctl list devices booted | grep -Fq "($simulator_id) (Booted)"; then
  xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b

cd "$repo_root/packages/yl_player/example"
flutter test integration_test/hls_playback_test.dart -d "$simulator_id"
flutter test integration_test/ios_mkv_playback_test.dart -d "$simulator_id"
flutter test integration_test/ios_network_mkv_playback_test.dart -d "$simulator_id"
