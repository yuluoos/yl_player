set -eu
mode=all
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
