#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-opus-demux.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_opus_demux.m" -L"$prefix/lib" "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/test_opus_demux"
"$temporary/test_opus_demux" "$script_dir/../../../yl_player/example/assets/test_media/format_matrix/mkv-avc-opus.mkv"
