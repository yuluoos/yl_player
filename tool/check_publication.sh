#!/bin/sh

set -eu

YL_REPO_ROOT=$(git -C "$(dirname -- "$0")" rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"

mode=${1:-all}
case "$mode" in
  all|--archives-only) ;;
  *)
    echo "usage: $0 [--archives-only]" >&2
    exit 64
    ;;
esac

core_release_version=0.3.0-dev.1
apple_release_version=0.3.0-dev.2
source_resolver_release_version=0.3.0-dev.2
package_names='yl_player_platform_interface yl_player_media_core yl_player_media_delivery yl_player_android yl_player_apple yl_player_source_resolver yl_player yl_player_cast yl_player_cast_player_adapter'
log_root=${YL_PUBLICATION_LOG_DIR:-}
cleanup_logs=0
if [ -z "$log_root" ]; then
  log_root=$(mktemp -d "${TMPDIR:-/tmp}/yl-player-publish.XXXXXX")
  cleanup_logs=1
fi
mkdir -p "$log_root"
if [ "$cleanup_logs" -eq 1 ]; then
  trap 'rm -rf "$log_root"' EXIT HUP INT TERM
fi

for package_name in $package_names; do
  package="packages/$package_name"
  case "$package_name" in
    yl_player_apple) expected_version=$apple_release_version ;;
    yl_player_source_resolver) expected_version=$source_resolver_release_version ;;
    *) expected_version=$core_release_version ;;
  esac
  actual_version=$(awk '$1 == "version:" { print $2; exit }' "$package/pubspec.yaml")
  if [ "$actual_version" != "$expected_version" ]; then
    echo "$package_name version is $actual_version; expected $expected_version" >&2
    exit 1
  fi
  for required in README.md CHANGELOG.md LICENSE; do
    if [ ! -s "$package/$required" ]; then
      echo "$package_name is missing nonempty $required" >&2
      exit 1
    fi
  done
done

if grep -nE '^[[:space:]]+path:' \
  packages/yl_player/pubspec.yaml \
  packages/yl_player_platform_interface/pubspec.yaml \
  packages/yl_player_android/pubspec.yaml \
  packages/yl_player_apple/pubspec.yaml \
  packages/yl_player_media_core/pubspec.yaml \
  packages/yl_player_media_delivery/pubspec.yaml \
  packages/yl_player_source_resolver/pubspec.yaml \
  packages/yl_player_cast/pubspec.yaml \
  packages/yl_player_cast_player_adapter/pubspec.yaml; then
  echo 'Publishable packages contain path dependencies.' >&2
  exit 1
fi

for dependency in yl_player_platform_interface yl_player_android yl_player_apple; do
  if ! grep -Eq "^[[:space:]]+$dependency: \^$core_release_version$" \
    packages/yl_player/pubspec.yaml; then
    echo "yl_player must constrain $dependency to ^$core_release_version" >&2
    exit 1
  fi
done
for package in \
  packages/yl_player_android \
  packages/yl_player_apple \
  packages/yl_player_source_resolver \
  packages/yl_player_cast \
  packages/yl_player_cast_player_adapter; do
  if ! grep -Eq "^[[:space:]]+yl_player_platform_interface: \^$core_release_version$" \
    "$package/pubspec.yaml"; then
    echo "$package must constrain yl_player_platform_interface to ^$core_release_version" >&2
    exit 1
  fi
done

for example in \
  packages/yl_player/example \
  packages/yl_player_android/example \
  packages/yl_player_source_resolver/example \
  packages/yl_player_cast/example; do
  publish_to=$(awk '$1 == "publish_to:" { value=$2; gsub(/[\047\"]/, "", value); print value; exit }' "$example/pubspec.yaml")
  if [ "$publish_to" != none ]; then
    echo "$example must remain publish_to: none." >&2
    exit 1
  fi
done

run_logged() {
  label=$1
  shift
  log="$log_root/$label.log"
  if "$@" >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi
  cat "$log"
  echo "GATE_EXIT gate=$label exit=$status"
  [ "$status" -eq 0 ] || exit "$status"
}

if [ "$mode" = all ]; then
  run_logged android-pigeon sh packages/yl_player_android/tool/check_pigeon.sh
  run_logged apple-pigeon sh packages/yl_player_apple/tool/check_pigeon.sh
  run_logged apple-artifact \
    python3 packages/yl_player_media_core/tool/apple_ffmpeg/verify_artifact.py
fi

for package_name in $package_names; do
  package="packages/$package_name"
  log="$log_root/$package_name-dry-run.log"
  echo "==> dart pub publish --dry-run ($package_name)"
  if (cd "$package" && dart pub publish --dry-run) >"$log" 2>&1; then
    status=0
  else
    status=$?
  fi
  cat "$log"
  echo "DRY_RUN_EXIT package=$package_name exit=$status"
  if [ "$status" -ne 0 ]; then
    exit "$status"
  fi
  if ! grep -Eq '^Package has 0 warnings( and [0-9]+ hints?)?\.$' "$log"; then
    echo "$package_name dry-run did not report zero warnings" >&2
    exit 1
  fi
  if grep -Eq '(^|[[:space:]│├└─])(\.dart_tool|build|\.gradle|\.swiftpm|DerivedData|Pods|\.symlinks|coverage)([[:space:]/(]|$)|\.xcresult([[:space:]/(]|$)|test_media([[:space:]/(]|$)|\.log([[:space:](]|$)|\.env([[:space:](]|$)' "$log"; then
    echo "$package_name archive contains a build/cache/test-media/secret-log path" >&2
    exit 1
  fi
done

apple_log="$log_root/yl_player_media_core-dry-run.log"
for required in \
  'FFmpeg-LGPL-2.1-or-later.txt' \
  'THIRD_PARTY_NOTICES.md' \
  'YlFFmpegBridge.xcframework'; do
  if ! grep -Fq "$required" "$apple_log"; then
    echo "yl_player_media_core archive is missing $required" >&2
    exit 1
  fi
done

echo "Publication gate passed for all publishable packages."
