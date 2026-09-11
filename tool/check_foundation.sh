#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

mode=${1:-all}
case "$mode" in
  all|--release-core) ;;
  *)
    echo "usage: $0 [--release-core]" >&2
    exit 64
    ;;
esac

python3 tool/test_android_scripts.py
python3 -B -m unittest tool.test_native_apple_scripts
if [ "$mode" = all ]; then
  python3 -B -m unittest tool.test_public_surface
  sh tool/check_public_surface.sh
fi
python3 -B tool/consumer_fixtures/apple_flutter/test_behavioral_constants.py
python3 -B tool/consumer_fixtures/apple_flutter/test_historical_migration.py
python3 -B tool/consumer_fixtures/apple_flutter/test_historical_origins.py
python3 -B tool/consumer_fixtures/apple_flutter/test_consumer_root.py
python3 -B tool/consumer_fixtures/apple_flutter/test_main_example_migration.py
python3 -B tool/consumer_fixtures/apple_flutter/test_runtime_evidence.py
python3 -B tool/consumer_fixtures/apple_flutter/test_source_parity.py
flutter pub get
if [ "$mode" = all ]; then
  flutter analyze
fi
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player/test
(cd packages/yl_player/example && flutter test test)
flutter test packages/yl_player_android/test
flutter test packages/yl_player_android/example/test
flutter test packages/yl_player_apple/test
if [ "$mode" = all ]; then
  sh packages/yl_player_apple/tool/check_pigeon.sh
fi
python3 -B tool/consumer_fixtures/apple_flutter/source_parity.py --verify-identical
python3 -B tool/consumer_fixtures/apple_flutter/behavioral_constants.py
if [ "$mode" = all ] && [ "$(uname -s)" = "Darwin" ]; then
  sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
elif [ "$mode" = all ]; then
  echo "Apple FFmpeg binary contract: skipped (requires macOS)"
fi
# Pinned Pigeon output is verified byte-for-byte by check_pigeon.sh.
# Keep every handwritten schema, adapter and test in the formatting gate.
if [ "$mode" = all ]; then
  find packages -name '*.dart' \
    ! -path '*/.dart_tool/*' ! -path '*/build/*' \
    ! -path 'packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart' \
    ! -path 'packages/yl_player_apple/lib/src/pigeon/yl_player_apple.g.dart' \
    -print0 | xargs -0 dart format --output=none --set-exit-if-changed
fi
