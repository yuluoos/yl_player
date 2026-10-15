#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Use the headers/libraries from a retained, pinned macosx-arm64 build for
# release verification. Homebrew FFmpeg is convenient for development tests.
 : "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
ffmpeg_prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-video-metadata.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$ffmpeg_prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" \
  -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
  "$script_dir/test_video_metadata.m" -L"$ffmpeg_prefix/lib" \
  "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security \
  -o "$temporary/test_video_metadata"
"$temporary/test_video_metadata" "$@"

sh "$script_dir/test_transport_stream.sh"

sh "$script_dir/test_avi.sh"

sh "$script_dir/test_vp9_metadata.sh"

sh "$script_dir/test_packet_framing.sh"

sh "$script_dir/test_program_stream.sh"
