#!/bin/sh
set -eu

YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)

cd "$YL_REPO_ROOT/packages/yl_player_apple"
dart run pigeon --input pigeons/yl_player_apple.dart
