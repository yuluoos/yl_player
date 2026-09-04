#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

flutter pub get
flutter analyze
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player/test
(cd packages/yl_player/example && flutter test test)
flutter test packages/yl_player_android/test
flutter test packages/yl_player_android/example/test
flutter test packages/yl_player_ios/test
flutter test packages/yl_player_ios/example/test
flutter test packages/yl_player_macos/test
sh packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh
if [ "$(uname -s)" = "Darwin" ]; then
  sh packages/yl_player_macos/tool/macos_ffmpeg/test_build_contract.sh
else
  echo "macOS FFmpeg ABI smoke: skipped (requires macOS)"
fi
dart format --output=none --set-exit-if-changed packages
