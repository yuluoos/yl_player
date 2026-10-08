#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
opus="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-packet-framing.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -I"$opus/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_packet_framing.m" "$opus/lib/libopus.a" -L"$prefix/lib" -lavformat -lavcodec -lavutil \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/test"
"$temporary/test" "$script_dir/../../../yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv"
