#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-all}

case "$mode" in
  all|--unit-only) ;;
  *)
    echo "usage: $0 [--unit-only]" >&2
    exit 64
    ;;
esac

cd "$repo_root/packages/yl_player/example"
flutter build macos --debug --config-only
(cd macos && pod install)

xcodebuild test -quiet \
  -workspace "$repo_root/packages/yl_player/example/macos/Runner.xcworkspace" \
  -scheme Runner \
  -destination 'platform=macOS'

if [ "$mode" = "--unit-only" ]; then
  exit 0
fi

echo "macOS integration verification is not implemented." >&2
exit 1
