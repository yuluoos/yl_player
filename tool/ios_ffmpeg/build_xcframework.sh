#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
exec sh "$repo_root/packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh" "$@"
