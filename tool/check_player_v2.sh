#!/bin/sh

set -eu

YL_REPO_ROOT=$(git -C "$(dirname -- "$0")" rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"

mode=--full
stage=all
no_device=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick|--full|--aggregate-quick|--aggregate-full) mode=$1 ;;
    --no-device) no_device=1 ;;
    --stage)
      shift
      [ "$#" -gt 0 ] || { echo '--stage requires a value' >&2; exit 64; }
      stage=$1
      ;;
    *)
      echo "usage: $0 [--quick|--full|--aggregate-quick|--aggregate-full] [--no-device] [--stage NAME]" >&2
      exit 64
      ;;
  esac
  shift
done

if [ "$no_device" -eq 1 ] && [ "$stage" != all ]; then
  echo '--no-device cannot be combined with a CI stage shard' >&2
  exit 64
fi

test_mode=${YL_GATE_TEST_MODE:-0}

step() {
  echo "PLAYER_V2_STEP $1"
}

run() {
  if [ "$test_mode" = 1 ]; then
    echo "WOULD_RUN $*"
  else
    "$@"
  fi
}

run_in() {
  directory=$1
  shift
  if [ "$test_mode" = 1 ]; then
    echo "WOULD_RUN_IN $directory $*"
  else
    (cd "$directory" && "$@")
  fi
}

format_check() {
  if [ "$test_mode" = 1 ]; then
    echo 'WOULD_RUN dart format --output=none --set-exit-if-changed <handwritten Dart>'
    return
  fi
  find packages -name '*.dart' \
    ! -path '*/.dart_tool/*' ! -path '*/build/*' \
    ! -path 'packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart' \
    ! -path 'packages/yl_player_apple/lib/src/pigeon/yl_player_apple.g.dart' \
    -print0 | xargs -0 dart format --output=none --set-exit-if-changed
}

collect_changes() {
  if [ "$test_mode" = 1 ] && [ -n "${YL_GATE_CHANGED_PATHS_OVERRIDE:-}" ]; then
    changed_paths=$YL_GATE_CHANGED_PATHS_OVERRIDE
    echo 'AFFECTED_SELECTION=override'
    return
  fi
  base=${YL_BASE_REF:-}
  if [ -z "$base" ] || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    changed_paths='*'
    echo 'AFFECTED_SELECTION=all reason=missing-or-invalid-YL_BASE_REF'
    return
  fi
  changed_paths=$(
    {
      git diff --name-only "$base"...HEAD
      git diff --name-only
      git diff --cached --name-only
      git ls-files --others --exclude-standard
    } | sort -u
  )
  echo "AFFECTED_SELECTION=diff base=$base"
}

affects_android() {
  [ "$changed_paths" = '*' ] || printf '%s\n' "$changed_paths" | grep -Eq \
    '^(packages/yl_player_android/|packages/yl_player_platform_interface/|packages/yl_player/(lib|example)/|pubspec\.yaml$|tool/|\.github/workflows/)'
}

affects_apple() {
  [ "$changed_paths" = '*' ] || printf '%s\n' "$changed_paths" | grep -Eq \
    '^(packages/yl_player_apple/|packages/yl_player_platform_interface/|packages/yl_player/(lib|example)/|pubspec\.yaml$|tool/|\.github/workflows/)'
}

android_unit() {
  step 'android-jvm-unit'
  run_in packages/yl_player_android/example/android \
    ./gradlew :yl_player_android:testDebugUnitTest --stacktrace
}

apple_unit() {
  step 'apple-ios-native-unit'
  if [ "$test_mode" != 1 ] && [ "$(uname -s)" != Darwin ]; then
    echo 'Required Apple unit suites need macOS; use a macOS CI shard.' >&2
    exit 1
  fi
  if [ "$test_mode" != 1 ] && [ -z "${YL_IOS_SIMULATOR_ID:-}" ]; then
    echo 'Set YL_IOS_SIMULATOR_ID to a verified booted Simulator.' >&2
    exit 1
  fi
  run sh tool/check_native_ios.sh --unit-only
  step 'apple-macos-native-unit'
  run sh tool/check_native_macos.sh --unit-only
}

quick_common() {
  step 'quick-format'
  format_check
  step 'quick-analysis'
  run flutter analyze
  step 'quick-dart-and-conformance'
  run sh tool/check_foundation.sh --release-core
  step 'quick-public-surface'
  run python3 -B -m unittest tool.test_public_surface
  run sh tool/check_public_surface.sh
  step 'quick-pigeon-drift'
  run sh packages/yl_player_android/tool/check_pigeon.sh
  run sh packages/yl_player_apple/tool/check_pigeon.sh
  step 'quick-recorded-artifact-contract'
  run python3 packages/yl_player_apple/tool/apple_ffmpeg/verify_artifact.py
}

run_quick() {
  collect_changes
  case "$stage" in
    all)
      quick_common
      if affects_android; then android_unit; else echo 'UNAFFECTED android-jvm-unit'; fi
      if affects_apple; then apple_unit; else echo 'UNAFFECTED apple-native-unit'; fi
      ;;
    common) quick_common ;;
    android-unit)
      if affects_android; then android_unit; else echo 'UNAFFECTED android-jvm-unit'; fi
      ;;
    apple-unit)
      if affects_apple; then apple_unit; else echo 'UNAFFECTED apple-native-unit'; fi
      ;;
    *)
      echo "unknown quick stage: $stage" >&2
      exit 64
      ;;
  esac
  if [ "$test_mode" = 1 ]; then
    echo "PLAYER_V2_TEST_MODE_COMPLETE mode=quick stage=$stage release_evidence=false"
  elif [ "$stage" != all ]; then
    echo "CI_SHARD_ONLY mode=quick stage=$stage"
  else
    echo 'PLAYER_V2_QUICK_PASS'
  fi
}

full_drift() {
  step '01-pigeon-drift'
  run sh packages/yl_player_android/tool/check_pigeon.sh
  run sh packages/yl_player_apple/tool/check_pigeon.sh
}

full_artifact() {
  step '02-combined-ffmpeg-artifact-contract'
  run sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
  if [ "${YL_REPRODUCIBILITY:-0}" = 1 ]; then
    step '02b-clean-ffmpeg-reproducibility'
    run sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check
  fi
}

full_foundation() {
  step '03-foundation'
  run sh tool/check_foundation.sh --release-core
}

android_device() {
  expected_api=$1
  device_id=$2
  step "04-android-api-$expected_api-integration"
  if [ "$test_mode" != 1 ]; then
    [ -n "$device_id" ] || {
      echo "Required Android API $expected_api device is unavailable." >&2
      exit 1
    }
    actual_api=$(adb -s "$device_id" shell getprop ro.build.version.sdk | tr -d '\r')
    [ "$actual_api" = "$expected_api" ] || {
      echo "Android device $device_id is API $actual_api, expected $expected_api." >&2
      exit 1
    }
  fi
  if [ "$test_mode" = 1 ]; then
    echo "WOULD_RUN Android API $expected_api on $device_id"
  else
    YL_ANDROID_DEVICE_ID=$device_id YL_ANDROID_SKIP_JVM=1 \
      sh tool/check_native_android.sh
  fi
}

full_ios() {
  step '05-ios-native-and-integration'
  run sh tool/check_native_ios.sh
}

full_macos() {
  step '06-macos-native-universal-rosetta-integration'
  run sh tool/check_native_macos.sh
}

full_consumers() {
  step '07-consumer-fixtures'
  run sh tool/check_consumers.sh
}

full_public_surface() {
  step '08-public-surface'
  run python3 -B -m unittest tool.test_public_surface
  run sh tool/check_public_surface.sh
}

full_publication() {
  step '09-publication-dry-run'
  run sh tool/check_publication.sh --archives-only
}

full_final() {
  step '10-format-analyze-diff-check'
  format_check
  run flutter analyze
  run git diff --check
}

run_full() {
  case "$stage" in
    all)
      full_drift
      full_artifact
      full_foundation
      android_unit
      if [ "$no_device" -eq 1 ]; then
        echo 'UNVERIFIED_REQUIRED Android API 24 integration skipped by --no-device'
        echo 'UNVERIFIED_REQUIRED Android API 36 integration skipped by --no-device'
        echo 'UNVERIFIED_REQUIRED iOS Simulator integration skipped by --no-device'
      else
        android_device 24 "${YL_ANDROID_API24_DEVICE_ID:-}"
        android_device 36 "${YL_ANDROID_API36_DEVICE_ID:-}"
        full_ios
      fi
      full_macos
      full_consumers
      full_public_surface
      full_publication
      full_final
      if [ "$test_mode" = 1 ]; then
        echo 'PLAYER_V2_TEST_MODE_COMPLETE mode=full stage=all release_evidence=false'
      elif [ "$no_device" -eq 1 ]; then
        echo 'PLAYER_V2_DIAGNOSTIC_COMPLETE release_evidence=false'
      else
        echo 'PLAYER_V2_FULL_PASS'
      fi
      ;;
    drift) full_drift ;;
    artifact) full_artifact ;;
    foundation) full_foundation ;;
    android-unit) android_unit ;;
    android-device)
      case "${YL_ANDROID_API:-}" in
        24|36) android_device "$YL_ANDROID_API" "${YL_ANDROID_DEVICE_ID:-}" ;;
        *) echo 'YL_ANDROID_API must be 24 or 36' >&2; exit 2 ;;
      esac
      ;;
    ios) full_ios ;;
    macos) full_macos ;;
    consumers) full_consumers ;;
    public-surface) full_public_surface ;;
    publication) full_publication ;;
    final) full_final ;;
    *) echo "unknown full stage: $stage" >&2; exit 64 ;;
  esac
  if [ "$test_mode" = 1 ] && [ "$stage" != all ]; then
    echo "PLAYER_V2_TEST_MODE_COMPLETE mode=full stage=$stage release_evidence=false"
  elif [ "$stage" != all ]; then
    echo "CI_SHARD_ONLY mode=full stage=$stage"
  fi
}

require_success() {
  label=$1
  result=$2
  if [ "$result" != success ]; then
    echo "Required $label result was ${result:-missing}." >&2
    return 1
  fi
}

aggregate_full() {
  require_success foundation "${YL_RESULT_FOUNDATION:-}"
  require_success android-unit "${YL_RESULT_ANDROID_UNIT:-}"
  require_success android-api-matrix "${YL_RESULT_ANDROID_INTEGRATION:-}"
  require_success ios "${YL_RESULT_IOS:-}"
  require_success macos "${YL_RESULT_MACOS:-}"
  require_success android-consumer "${YL_RESULT_ANDROID_CONSUMER:-}"
  require_success apple-consumers "${YL_RESULT_APPLE_CONSUMERS:-}"
  require_success ffmpeg-reproducibility "${YL_RESULT_REPRODUCIBILITY:-}"
  if [ "$test_mode" = 1 ]; then
    echo 'PLAYER_V2_TEST_MODE_COMPLETE aggregate=full release_evidence=false'
  else
    echo 'PLAYER_V2_FULL_CI_AGGREGATE_PASS'
  fi
}

aggregate_quick() {
  require_success foundation "${YL_RESULT_FOUNDATION:-}"
  if [ "${YL_SELECTED_ANDROID:-false}" = true ]; then
    require_success android-unit "${YL_RESULT_ANDROID_UNIT:-}"
    require_success android-integration "${YL_RESULT_ANDROID_INTEGRATION:-}"
  fi
  if [ "${YL_SELECTED_APPLE:-false}" = true ]; then
    require_success apple-unit "${YL_RESULT_APPLE_UNIT:-}"
    require_success ios-integration "${YL_RESULT_IOS:-}"
    require_success macos-integration "${YL_RESULT_MACOS:-}"
  fi
  if [ "${YL_SELECTED_CONSUMERS:-false}" = true ]; then
    require_success android-consumer "${YL_RESULT_ANDROID_CONSUMER:-}"
    require_success apple-consumers "${YL_RESULT_APPLE_CONSUMERS:-}"
  fi
  if [ "${YL_SELECTED_ARTIFACT:-false}" = true ]; then
    require_success ffmpeg-reproducibility "${YL_RESULT_REPRODUCIBILITY:-}"
  fi
  if [ "$test_mode" = 1 ]; then
    echo 'PLAYER_V2_TEST_MODE_COMPLETE aggregate=quick release_evidence=false'
  else
    echo 'PLAYER_V2_QUICK_CI_AGGREGATE_PASS'
  fi
}

case "$mode" in
  --quick) run_quick ;;
  --full) run_full ;;
  --aggregate-quick) aggregate_quick ;;
  --aggregate-full) aggregate_full ;;
esac
