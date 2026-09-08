#!/bin/sh
set -eu

YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)

sh "$YL_SCRIPT_DIR/generate_pigeon.sh"
git -C "$YL_REPO_ROOT" diff --exit-code -- \
  packages/yl_player_apple/lib/src/pigeon/yl_player_apple.g.dart \
  packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Generated/YlPlayerApple.g.swift
