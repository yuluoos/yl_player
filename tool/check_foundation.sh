#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

flutter pub get
flutter analyze
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player/test
flutter test packages/yl_player/example/test
flutter test packages/yl_player_android/test
flutter test packages/yl_player_android/example/test
flutter test packages/yl_player_ios/test
flutter test packages/yl_player_ios/example/test
sh packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh
dart format --output=none --set-exit-if-changed packages
