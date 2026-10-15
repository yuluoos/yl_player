#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed source build}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
opus="${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}"
dav1d="${YL_TEST_DAV1D_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/dav1d-stage/yl_dav1d/install}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/yl-unadmitted-probe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
xcrun clang -fobjc-arc -I"$opus/include" -I"$dav1d/include" -I"$prefix/include" \
 -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" \
 -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" "$script_dir/test_unadmitted_probe.m" \
 -L"$prefix/lib" "$opus/lib/libopus.a" -lavformat -lavcodec -lavutil "$dav1d/lib/libdav1d.a" \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$tmp/test"
root=$(CDPATH= cd -- "$script_dir/../../../.." && pwd)
failed=0
for name in mkv-av1-opus.mkv webm-vp9-vorbis.webm; do
 "$tmp/test" "$root/packages/yl_player/example/assets/test_media/format_matrix/$name" || failed=1
done
exit "$failed"
