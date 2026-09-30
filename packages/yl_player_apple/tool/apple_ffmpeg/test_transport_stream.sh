#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-ts-timeline.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_transport_stream.m" -L"$prefix/lib" "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/test_ts"
# Owned synthetic media: only the first frame is independently decodable.
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:r=2:d=12 \
 -c:v libx264 -g 120 -keyint_min 120 -sc_threshold 0 -bf 0 -an -f mpegts "$temporary/sparse.ts"
"$temporary/test_ts" "$script_dir/../../../yl_player/example/assets/test_media/format_matrix/ts-avc-ac3.ts" "$temporary/sparse.ts"
