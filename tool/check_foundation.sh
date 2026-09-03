#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

flutter pub get
flutter analyze
flutter test packages/yl_player_platform_interface
flutter test packages/yl_player
flutter test packages/yl_player_android
flutter test packages/yl_player_ios
dart format --output=none --set-exit-if-changed packages
