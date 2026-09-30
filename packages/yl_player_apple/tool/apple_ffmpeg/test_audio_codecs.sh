#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Link the production minimal FFmpeg libraries for release verification.
# A full FFmpeg executable is used only to generate temporary synthetic media.
 : "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
ffmpeg_prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
fixture_ffmpeg=${YL_FIXTURE_FFMPEG:-/opt/homebrew/bin/ffmpeg}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-audio-codecs.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
"$fixture_ffmpeg" -hide_banner -loglevel error -f lavfi \
  -i 'anullsrc=r=48000:cl=stereo' -t 0.1 -c:a ac3 "$temporary/ac3.mkv"
"$fixture_ffmpeg" -hide_banner -loglevel error -f lavfi \
  -i 'anullsrc=r=48000:cl=5.1' -t 0.1 -c:a eac3 "$temporary/eac3.mkv"
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$ffmpeg_prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" \
  -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
  "$script_dir/test_audio_codecs.m" -L"$ffmpeg_prefix/lib" \
  "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
  -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security \
  -o "$temporary/test_audio_codecs"
"$temporary/test_audio_codecs" "$temporary/ac3.mkv" "$temporary/eac3.mkv" "$@"

sh "$script_dir/test_opus.sh"

sh "$script_dir/test_opus_demux.sh"

sh "$script_dir/test_vorbis.sh"
