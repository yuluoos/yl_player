#!/bin/sh
set -eu

YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)

sh "$YL_SCRIPT_DIR/generate_pigeon.sh"
git -C "$YL_REPO_ROOT" diff --exit-code -- \
  packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart \
  packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt
