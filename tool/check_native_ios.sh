#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-all}
simulator_id=${YL_IOS_SIMULATOR_ID:-}
evidence_root=${YL_APPLE_EVIDENCE_DIR:-"$repo_root/packages/yl_player/example/build/apple-evidence"}
mkdir -p "$evidence_root"
evidence=$(mktemp -d "$evidence_root/ios.XXXXXX")

case "$mode" in
  all|--unit-only|--integration-only) ;;
  *)
    echo "usage: $0 [--unit-only|--integration-only]" >&2
    exit 64
    ;;
esac


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

partition=${YL_IOS_TEST_TARGET:-}
case "$partition" in
  physical) simulator_id=${YL_IOS_DEVICE_ID:?Physical iOS device ID required} ;;
  simulator|'') ;;
  *) echo 'Unknown iOS test target' >&2; exit 2 ;;
esac

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

if [ -n "$partition" ]; then
  python3 -B "$repo_root/tool/ci_playback_shards.py" verify-ios "$partition" "$simulator_id" --evidence "$evidence"
fi

if [ "$mode" != "--integration-only" ]; then
  # Integration tests replace Flutter's generated Dart entrypoint with a
  # temporary listener. Restore the normal example configuration before invoking
  # Xcode directly so a previous test run cannot poison the native test build.
  (
    cd "$repo_root/packages/yl_player/example"
    if [ "$partition" = physical ]; then
      flutter build ios --debug --config-only --no-pub
    else
      flutter build ios --simulator --debug --config-only
    fi
  )
  python3 -B "$repo_root/tool/consumer_fixtures/apple_flutter/main_example_tests.py" --current-only
  verify_registrant

  if [ -n "$partition" ]; then
    python3 -B "$repo_root/tool/ci_playback_shards.py" ios-native "$partition" "$simulator_id" --evidence "$evidence"
  else
    native_status=0
    xcodebuild test CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -quiet -sdk iphonesimulator \
      -workspace "$repo_root/packages/yl_player/example/ios/Runner.xcworkspace" \
      -scheme Runner \
      -parallel-testing-enabled NO \
      -derivedDataPath "$repo_root/packages/yl_player/example/build/native-ios-tests" \
      -destination "platform=iOS Simulator,id=$simulator_id" \
      -resultBundlePath "$evidence/native.xcresult" >"$evidence/native.log" 2>&1 || native_status=$?
    cat "$evidence/native.log"
    python3 -B "$repo_root/tool/consumer_fixtures/apple_flutter/main_example_tests.py" \
      --result-bundle "$evidence/native.xcresult" --platform ios --output "$evidence/runtime"
    [ "$native_status" -eq 0 ]
  fi
fi

if [ "$mode" = "--unit-only" ]; then
  exit 0
fi

if [ "$partition" = physical ]; then
  exec python3 -B "$repo_root/tool/ci_playback_shards.py" ios-flutter physical "$simulator_id" --evidence "$evidence"
fi

# xcodebuild can shut down the source simulator after running tests on a clone.
# Restore it before Flutter tries to discover the requested device.
if ! xcrun simctl list devices booted | grep -Fq "($simulator_id) (Booted)"; then
  xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b

if [ "$partition" = simulator ]; then
  exec python3 -B "$repo_root/tool/ci_playback_shards.py" ios-flutter simulator "$simulator_id" --evidence "$evidence"
fi
cd "$repo_root/packages/yl_player/example"
# Discover the authenticated VM endpoint from the launched process history.
# Streaming-only discovery can miss the startup line on a busy Simulator.
integration_status=0
for test_file in \
  integration_test/hls_playback_test.dart \
  integration_test/apple_default_positive_test.dart \
  integration_test/state_update_cadence_test.dart \
  integration_test/apple_strict_policy_test.dart
do
  integration_log="$evidence/$(basename "$test_file").log"
  suite_status=0
  python3 -B "$repo_root/tool/run_ios_simulator_integration.py" \
    --simulator "$simulator_id" --test "$test_file" --evidence "$evidence" >"$integration_log" 2>&1 || suite_status=$?
  cat "$integration_log"
  if [ "$suite_status" -ne 0 ]; then
    # A completed suite writes its own receipt. Keep testing independent suites
    # after a case failure, but stop on build, launch, or driver startup errors.
    suite_name=$(basename "$test_file" .dart)
    [ -s "$evidence/$suite_name/integration_response_data.json" ] || exit "$suite_status"
    integration_status=1
  fi
done
exit "$integration_status"
