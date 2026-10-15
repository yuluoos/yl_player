#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed source build}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
opus="${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/yl-software-video.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
xcrun clang -fobjc-arc -I"$opus/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_software_video.m" -L"$prefix/lib" "$opus/lib/libopus.a" -lavformat -lavcodec -lavutil \
 ${YL_TEST_DAV1D_LIB:+"$YL_TEST_DAV1D_LIB"} \
 ${YL_TEST_DAV1D_PREFIX:+-I"$YL_TEST_DAV1D_PREFIX/include"} \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$tmp/test"
xcrun clang -fobjc-arc -I"$opus/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_software_video_file.m" -L"$prefix/lib" "$opus/lib/libopus.a" -lavformat -lavcodec -lavutil \
 ${YL_TEST_DAV1D_LIB:+"$YL_TEST_DAV1D_LIB"} \
 ${YL_TEST_DAV1D_PREFIX:+-I"$YL_TEST_DAV1D_PREFIX/include"} \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$tmp/file"
root=$(CDPATH= cd -- "$script_dir/../../../.." && pwd)
python3 -B "$script_dir/software_video_reference.py" "$tmp"
for name in av1-main8 av1-main10 vp9-main8; do "$tmp/test" "$tmp/$name.json" "$tmp/$name.yuv"; done
for name in av1-main8 av1-main10 vp9-main8; do "$tmp/file" "$tmp/$name.json" "$tmp/$name.mkv" "$tmp/$name.yuv"; done
if [ -n "${YL_SOFTWARE_FRAMEWORK_DIR:-}" ]; then
 xcrun clang -fobjc-arc -DYL_SOFTWARE_ARTIFACT=1 -F"$YL_SOFTWARE_FRAMEWORK_DIR" -Wl,-rpath,"$YL_SOFTWARE_FRAMEWORK_DIR" \
  "$script_dir/test_software_video_file.m" -framework YlFFmpegBridge -framework Foundation -framework CoreMedia -framework CoreVideo -o "$tmp/artifact"
 for name in av1-main8 av1-main10 vp9-main8; do "$tmp/artifact" "$tmp/$name.json" "$tmp/$name.mkv" "$tmp/$name.yuv"; done
fi
