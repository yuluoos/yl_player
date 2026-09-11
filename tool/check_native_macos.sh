#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-all}
example_root="$repo_root/packages/yl_player/example"
evidence_root=${YL_APPLE_EVIDENCE_DIR:-"$example_root/build/apple-evidence"}
mkdir -p "$evidence_root"
evidence=$(mktemp -d "$evidence_root/macos.XXXXXX")

verify_registrant() {
  registrant="$example_root/macos/Flutter/GeneratedPluginRegistrant.swift"
  package_graph="$example_root/macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
  if ! grep -Fq 'YlPlayerApplePlugin' "$registrant" || ! grep -Fq 'yl_player_apple' "$package_graph"; then
    echo "macOS generated wiring omits yl_player_apple" >&2
    exit 1
  fi
  if grep -Eq 'yl_player_(ios|macos)|YlPlayer(Ios|Macos)Plugin' "$registrant" "$package_graph"; then
    echo "macOS registrant retains a legacy Apple plugin" >&2
    exit 1
  fi
  echo "macOS generated wiring: YlPlayerApplePlugin only"
}

case "$mode" in
  all|--unit-only|--build-only|--integration-only) ;;
  *)
    echo "usage: $0 [--unit-only|--build-only|--integration-only]" >&2
    exit 64
    ;;
esac

assert_architectures() {
  binary=$1
  label=$2
  architectures=$(lipo -archs "$binary")

  case " $architectures " in
    *" arm64 "*) ;;
    *)
      echo "$label is missing arm64: $architectures" >&2
      exit 1
      ;;
  esac

  case " $architectures " in
    *" x86_64 "*) ;;
    *)
      echo "$label is missing x86_64: $architectures" >&2
      exit 1
      ;;
  esac

  echo "$label architectures: $architectures"
}

run_unit_tests() {
  cd "$example_root"
  flutter build macos --debug --config-only
  (cd macos && pod install)
  python3 -B "$repo_root/tool/consumer_fixtures/apple_flutter/main_example_tests.py" --current-only
  verify_registrant

  native_status=0
  python3 -B "$repo_root/tool/run_with_display_awake.py" xcodebuild test -quiet -sdk macosx \
    -workspace "$example_root/macos/Runner.xcworkspace" \
    -scheme Runner \
    -parallel-testing-enabled NO \
    -derivedDataPath "$example_root/build/native-macos-tests" \
    -destination 'platform=macOS' \
    -resultBundlePath "$evidence/native.xcresult" >"$evidence/native.log" 2>&1 || native_status=$?
  cat "$evidence/native.log"
  python3 -B "$repo_root/tool/consumer_fixtures/apple_flutter/main_example_tests.py" \
    --result-bundle "$evidence/native.xcresult" --platform macos --output "$evidence/runtime"
  [ "$native_status" -eq 0 ]
}

run_rosetta_smoke() {
  executable=$1

  if ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    echo "Rosetta x86_64 smoke: skipped (x86_64 execution unavailable)"
    return
  fi

  smoke_log=$(mktemp "${TMPDIR:-/tmp}/yl-player-rosetta.XXXXXX")
  /usr/bin/arch -x86_64 "$executable" >"$smoke_log" 2>&1 &
  smoke_pid=$!
  sleep 3

  if kill -0 "$smoke_pid" >/dev/null 2>&1; then
    kill "$smoke_pid"
    wait "$smoke_pid" >/dev/null 2>&1 || true
    rm -f "$smoke_log"
    echo "Rosetta x86_64 smoke: passed"
    return
  fi

  set +e
  wait "$smoke_pid"
  smoke_status=$?
  set -e
  echo "Rosetta x86_64 smoke failed with exit code $smoke_status" >&2
  cat "$smoke_log" >&2
  rm -f "$smoke_log"
  exit 1
}

run_universal_build() {
  cd "$example_root"
  server_entitlement=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.network.server' \
    macos/Runner/Release.entitlements)
  if [ "$server_entitlement" != "true" ]; then
    echo "Release.entitlements must allow the authenticated-HLS loopback server" >&2
    exit 1
  fi
  sh "$repo_root/packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh"
  flutter build macos --release

  products="$example_root/build/macos/Build/Products/Release"
  app="$products/yl_player_example.app"
  executable="$app/Contents/MacOS/yl_player_example"
  flutter_binary="$app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
  dart_binary="$app/Contents/Frameworks/App.framework/Versions/A/App"
  ffmpeg_binary="$app/Contents/Frameworks/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge"
  plugin_intermediates="$example_root/build/macos/Build/Intermediates.noindex/yl_player_apple.build/Release/yl_player_apple.build/Objects-normal"

  assert_architectures "$executable" "macOS example executable"
  assert_architectures "$flutter_binary" "FlutterMacOS framework"
  assert_architectures "$dart_binary" "Dart App framework"
  assert_architectures "$ffmpeg_binary" "YlFFmpegBridge framework"

  for architecture in arm64 x86_64; do
    plugin_object="$plugin_intermediates/$architecture/Binary/yl_player_apple.o"
    if [ ! -f "$plugin_object" ]; then
      echo "yl_player_apple was not compiled for $architecture" >&2
      exit 1
    fi
    if [ "$(lipo -archs "$plugin_object")" != "$architecture" ]; then
      echo "yl_player_apple object has the wrong architecture for $architecture" >&2
      exit 1
    fi
    if ! nm -arch "$architecture" "$executable" | grep -q 'YlPlayerApplePlugin'; then
      echo "yl_player_apple was not linked into the $architecture executable" >&2
      exit 1
    fi
    echo "yl_player_apple $architecture compile/link: verified"
  done

  minimum_system_version=$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")
  if [ "$minimum_system_version" != "12.0" ]; then
    echo "unexpected minimum macOS version: $minimum_system_version" >&2
    exit 1
  fi
  echo "minimum macOS version: $minimum_system_version"

  if ! codesign -d --entitlements :- "$app" 2>&1 \
    | grep -Fq '<key>com.apple.security.network.server</key>'; then
    echo "release app is missing the authenticated-HLS network server entitlement" >&2
    exit 1
  fi
  echo "release network server entitlement: verified"

  run_rosetta_smoke "$executable"
}

run_integration_tests() {
  cd "$example_root"
  for test_file in \
    integration_test/macos_hls_playback_test.dart \
    integration_test/macos_mkv_playback_test.dart \
    integration_test/macos_network_mkv_playback_test.dart \
    integration_test/macos_http_flv_playback_test.dart \
    integration_test/state_update_cadence_test.dart \
    integration_test/apple_strict_policy_test.dart
  do
    integration_log="$evidence/$(basename "$test_file").log"
    if python3 -B "$repo_root/tool/run_with_display_awake.py" flutter test "$test_file" -d macos >"$integration_log" 2>&1; then
      cat "$integration_log"
    else
      cat "$integration_log"
      return 1
    fi
  done
}

if [ "$mode" = "--build-only" ]; then
  run_universal_build
  exit 0
fi

if [ "$mode" = "--integration-only" ]; then
  run_universal_build
  run_integration_tests
  exit 0
fi

run_unit_tests

if [ "$mode" = "--unit-only" ]; then
  exit 0
fi

run_universal_build
run_integration_tests
