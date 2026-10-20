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

python3 -B -m unittest discover -s tool/playback_network -p 'test_*.py'
python3 -B -m unittest discover -s tool/playback_benchmark -p 'test_*.py'
python3 -B -m unittest discover -s tool/dash_sidx -p 'test_*.py'
python3 -B -m unittest discover -s tool/dash_timeline -p 'test_*.py'
python3 -B -m unittest discover -s tool/drm_acceptance -p 'test_*.py'
python3 -B -m unittest discover -s tool/media_matrix -p 'test_*.py'
python3 -B -m unittest discover -s tool/decoder_probe -p 'test_*.py'
python3 -B tool/media_matrix/catalog.py
if [ "$(uname -s)" = Darwin ]; then
  sh tool/media_matrix/check_hevc_random_access.sh
  sh tool/media_matrix/check_vp9_headers.sh
fi
python3 -B -m unittest discover -s tool/dolby_reference -p 'test_*.py'
python3 -B tool/dolby_reference/inventory.py
python3 -B tool/protected_output/sync_apple_probe.py --check
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
flutter test packages/yl_player_media_delivery/test
flutter test packages/yl_player_cast/test
flutter test packages/yl_player_cast_player_adapter/test
python3 -B packages/yl_player_cast/tool/check_standalone_dependencies.py
if [ "$mode" = all ]; then
  sh packages/yl_player_apple/tool/check_pigeon.sh
fi
python3 -B tool/consumer_fixtures/apple_flutter/source_parity.py --verify-identical
python3 -B tool/consumer_fixtures/apple_flutter/behavioral_constants.py
if [ "$mode" = all ] && [ "$(uname -s)" = "Darwin" ]; then
  sh packages/yl_player_media_core/tool/apple_ffmpeg/test_build_contract.sh
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
