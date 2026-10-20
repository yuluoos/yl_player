#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
framework=${1:-"$script_dir/../../darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"}
fixture="$script_dir/../../../yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-length-prefix.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -F"$framework" -Wl,-rpath,"$framework" \
 "$script_dir/test_length_prefixed_packets.m" -framework Foundation -framework CoreMedia \
 -framework YlFFmpegBridge -o "$temporary/test"
"$temporary/test" "$fixture"
