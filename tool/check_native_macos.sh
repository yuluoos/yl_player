#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-all}
example_root="$repo_root/packages/yl_player/example"

case "$mode" in
  all|--unit-only|--build-only) ;;
  *)
    echo "usage: $0 [--unit-only|--build-only]" >&2
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

  xcodebuild test -quiet \
    -workspace "$example_root/macos/Runner.xcworkspace" \
    -scheme Runner \
    -destination 'platform=macOS'
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
  sh "$repo_root/packages/yl_player_macos/tool/macos_ffmpeg/test_build_contract.sh"
  flutter build macos --release

  products="$example_root/build/macos/Build/Products/Release"
  app="$products/yl_player_example.app"
  executable="$app/Contents/MacOS/yl_player_example"
  flutter_binary="$app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
  dart_binary="$app/Contents/Frameworks/App.framework/Versions/A/App"
  ffmpeg_binary="$app/Contents/Frameworks/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge"
  plugin_intermediates="$example_root/build/macos/Build/Intermediates.noindex/yl_player_macos.build/Release/yl_player_macos.build/Objects-normal"

  assert_architectures "$executable" "macOS example executable"
  assert_architectures "$flutter_binary" "FlutterMacOS framework"
  assert_architectures "$dart_binary" "Dart App framework"
  assert_architectures "$ffmpeg_binary" "YlFFmpegBridge framework"

  for architecture in arm64 x86_64; do
    plugin_object="$plugin_intermediates/$architecture/Binary/yl_player_macos.o"
    if [ ! -f "$plugin_object" ]; then
      echo "yl_player_macos was not compiled for $architecture" >&2
      exit 1
    fi
    if [ "$(lipo -archs "$plugin_object")" != "$architecture" ]; then
      echo "yl_player_macos object has the wrong architecture for $architecture" >&2
      exit 1
    fi
    if ! nm -arch "$architecture" "$executable" | grep -q 'YlPlayerMacosPlugin'; then
      echo "yl_player_macos was not linked into the $architecture executable" >&2
      exit 1
    fi
    echo "yl_player_macos $architecture compile/link: verified"
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
    integration_test/macos_hls_headers_playback_test.dart
  do
    flutter test "$test_file" -d macos
  done
}

if [ "$mode" = "--build-only" ]; then
  run_universal_build
  exit 0
fi

run_unit_tests

if [ "$mode" = "--unit-only" ]; then
  exit 0
fi

run_universal_build
run_integration_tests
