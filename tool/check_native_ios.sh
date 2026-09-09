#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
simulator_id=${YL_IOS_SIMULATOR_ID:-}

verify_registrant() {
  registrant="$repo_root/packages/yl_player/example/ios/Runner/GeneratedPluginRegistrant.m"
  package_graph="$repo_root/packages/yl_player/example/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
  if ! grep -Fq 'YlPlayerApplePlugin' "$registrant" || ! grep -Fq 'yl_player_apple' "$package_graph"; then
    echo "iOS generated wiring omits yl_player_apple" >&2
    exit 1
  fi
  if grep -Eq 'yl_player_(ios|macos)|YlPlayer(Ios|Macos)Plugin' "$registrant" "$package_graph"; then
    echo "iOS registrant retains a legacy Apple plugin" >&2
    exit 1
  fi
  echo "iOS generated wiring: YlPlayerApplePlugin only"
}

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
python3 -B "$repo_root/tool/consumer_fixtures/apple_flutter/main_example_tests.py" --current-only
verify_registrant

xcodebuild test -quiet \
  -workspace "$repo_root/packages/yl_player/example/ios/Runner.xcworkspace" \
  -scheme Runner \
  -parallel-testing-enabled NO \
  -derivedDataPath "$repo_root/packages/yl_player/example/build/native-ios-tests" \
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
flutter test integration_test/ios_http_flv_playback_test.dart -d "$simulator_id"
flutter test integration_test/ios_hls_headers_playback_test.dart -d "$simulator_id"
