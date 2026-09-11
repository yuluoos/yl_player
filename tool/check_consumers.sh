#!/bin/sh
set -eu

if [ -z "${YL_REPO_ROOT:-}" ]; then
  YL_REPO_ROOT=$(git rev-parse --show-toplevel)
fi
YL_REPO_ROOT=$(CDPATH= cd -- "$YL_REPO_ROOT" && pwd -P)
export YL_REPO_ROOT
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ "$SCRIPT_DIR" = "$YL_REPO_ROOT/tool" ] || { echo "YL_REPO_ROOT does not own check_consumers.sh" >&2; exit 2; }

case "${1:-}" in
  --list)
    printf '%s\n' android ios-cocoapods macos-cocoapods ios-swiftpm macos-swiftpm
    exit 0
    ;;
  "") mode=all ;;
  --android-only) mode=android ;;
  --apple-only) mode=apple ;;
  *) echo "usage: $0 [--list|--android-only|--apple-only]" >&2; exit 2 ;;
esac

flutter=${YL_FLUTTER:-}
if [ -z "$flutter" ]; then
  flutter=$(command -v flutter || true)
fi
[ -n "$flutter" ] && [ -x "$flutter" ] || { echo "Set YL_FLUTTER to the Flutter executable" >&2; exit 2; }
export YL_FLUTTER=$flutter

root_id=$(printf '%s' "$YL_REPO_ROOT" | shasum -a 256 | awk '{print substr($1,1,12)}')
consumer_output=${YL_CONSUMER_OUTPUT:-${TMPDIR:-/tmp}/yl-consumers-$root_id}
mkdir -p "$consumer_output"
consumer_output=$(CDPATH= cd -- "$consumer_output" && pwd -P)
case "$consumer_output/" in
  "$YL_REPO_ROOT/"*) echo "Consumer output must be outside the checkout" >&2; exit 2 ;;
esac
owner=$consumer_output/repo-root.txt
if [ -e "$owner" ]; then
  [ "$(sed -n '1p' "$owner")" = "$YL_REPO_ROOT" ] || { echo "Consumer output belongs to another checkout" >&2; exit 2; }
else
  printf '%s\n' "$YL_REPO_ROOT" > "$owner"
fi
logs=${YL_CONSUMER_LOG_DIR:-$consumer_output/logs}
mkdir -p "$logs"
logs=$(CDPATH= cd -- "$logs" && pwd -P)
export YL_APPLE_CONSUMERS=${YL_APPLE_CONSUMERS:-$consumer_output/apple}
export YL_APPLE_LOG_DIR=${YL_APPLE_LOG_DIR:-$logs}

run_logged() {
  name=$1
  shift
  log=$logs/$name.log
  printf '%s\n' "$*" > "$log.command"
  if "$@" > "$log" 2>&1; then
    printf '%s: passed (%s)\n' "$name" "$log"
  else
    status=$?
    tail -200 "$log" >&2
    printf '%s: failed with exit %s (%s)\n' "$name" "$status" "$log" >&2
    return "$status"
  fi
}

run_logged consumer-gate-tests python3 -B "$YL_REPO_ROOT/tool/test_consumers.py"
run_logged apple-link-inspection-tests python3 -B "$YL_REPO_ROOT/tool/consumer_fixtures/apple_flutter/test_link_inspection.py"

if [ "$mode" = all ] || [ "$mode" = android ]; then
  java_version=$(${JAVA_HOME:?Set JAVA_HOME to JDK 17}/bin/java -version 2>&1 | sed -n '1p')
  case "$java_version" in
    *'"17.'*) ;;
    *) echo "Android consumer requires Java 17; got $java_version" >&2; exit 2 ;;
  esac
  android_host=$consumer_output/android
  marker=$android_host/consumer-root.txt
  if [ -e "$android_host" ] && [ ! -e "$marker" ]; then
    echo "Unowned Android consumer exists at $android_host" >&2
    exit 2
  fi
  if [ ! -e "$marker" ]; then
    run_logged android-create "$flutter" create --no-pub --platforms android --android-language kotlin --project-name yl_consumer "$android_host"
    printf '%s\n' "$YL_REPO_ROOT" > "$marker"
  fi
  [ "$(sed -n '1p' "$marker")" = "$YL_REPO_ROOT" ] || { echo "Android consumer belongs to another checkout" >&2; exit 2; }
  cp "$YL_REPO_ROOT/tool/consumer_fixtures/android/settings.gradle.kts" "$android_host/android/settings.gradle.kts"
  cp "$YL_REPO_ROOT/tool/consumer_fixtures/android/build.gradle.kts" "$android_host/android/build.gradle.kts"
  cp "$YL_REPO_ROOT/tool/consumer_fixtures/android/app/build.gradle.kts" "$android_host/android/app/build.gradle.kts"
  cp "$YL_REPO_ROOT/tool/consumer_fixtures/android/app/src/main/AndroidManifest.xml" "$android_host/android/app/src/main/AndroidManifest.xml"
  mkdir -p "$android_host/android/app/src/main/kotlin/dev/ylplayer/consumer"
  cp "$YL_REPO_ROOT/tool/consumer_fixtures/android/app/src/main/kotlin/dev/ylplayer/consumer/ConsumerApplication.kt" "$android_host/android/app/src/main/kotlin/dev/ylplayer/consumer/ConsumerApplication.kt"
  cat > "$android_host/pubspec.yaml" <<EOF
name: yl_consumer
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  yl_player_android:
    path: $YL_REPO_ROOT/packages/yl_player_android
dependency_overrides:
  yl_player_platform_interface:
    path: $YL_REPO_ROOT/packages/yl_player_platform_interface
flutter:
  uses-material-design: false
EOF
  run_logged android-pub-get "$flutter" pub get --directory "$android_host"
  run_logged android-dependencies "$android_host/android/gradlew" -p "$android_host/android" :app:dependencies --configuration debugRuntimeClasspath
  grep -q 'project :yl_player_android' "$logs/android-dependencies.log" || { echo "Android graph omits yl_player_android" >&2; exit 1; }
  grep -q 'io.flutter:flutter_embedding_debug' "$logs/android-dependencies.log" || { echo "Android graph omits real Flutter embedding" >&2; exit 1; }
  run_logged android-assemble-debug "$android_host/android/gradlew" -p "$android_host/android" :app:assembleDebug --stacktrace
  apk=$android_host/build/app/outputs/apk/debug/app-debug.apk
  [ -f "$apk" ] || apk=$android_host/android/app/build/outputs/apk/debug/app-debug.apk
  [ -f "$apk" ] || { echo "Android consumer APK is missing" >&2; exit 1; }
  printf '{"case":"android","manager":"flutter-gradle","compileSdk":36,"minSdk":24,"java":17,"apk":"%s"}\n' "$apk" > "$logs/android-result.json"
fi

if [ "$mode" = all ] || [ "$mode" = apple ]; then
  run_logged ios-cocoapods sh "$YL_REPO_ROOT/tool/check_apple_consumer.sh" --platform ios --manager cocoapods --link
  run_logged macos-cocoapods sh "$YL_REPO_ROOT/tool/check_apple_consumer.sh" --platform macos --manager cocoapods --link
  run_logged ios-swiftpm sh "$YL_REPO_ROOT/tool/check_apple_consumer.sh" --platform ios --manager swiftpm --link
  run_logged macos-swiftpm sh "$YL_REPO_ROOT/tool/check_apple_consumer.sh" --platform macos --manager swiftpm --link
fi

printf 'Independent consumers passed: %s\n' "$mode"
