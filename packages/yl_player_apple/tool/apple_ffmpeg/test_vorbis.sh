#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
opus="${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}"
fixture_ffmpeg=${YL_FIXTURE_FFMPEG:-/opt/homebrew/bin/ffmpeg}
: "${YL_TEST_VORBIS_REFERENCE:?Set test-only Xiph reference install prefix}"
reference=$YL_TEST_VORBIS_REFERENCE
framework=${YL_VORBIS_FRAMEWORK_DIR:-"$script_dir/../../darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-vorbis.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
for rate in 44100 48000; do
 for channels in 1 2; do
  "$reference/bin/yl_vorbis_encoder" "$rate" "$channels" > "$temporary/$rate-$channels.ogg"
  "$fixture_ffmpeg" -hide_banner -loglevel error -i "$temporary/$rate-$channels.ogg" -c:a copy "$temporary/$rate-$channels.mkv"
 done
done
python3 - "$temporary" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);print('YL_VORBIS_FIXTURES='+json.dumps({p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(root.iterdir())},sort_keys=True))
PY
xcrun clang -fobjc-arc -I"$reference/include" -I"$opus/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_vorbis.m" -L"$prefix/lib" "$opus/lib/libopus.a" -lavformat -lavcodec -lavutil "$reference/lib/libvorbis.a" "$reference/lib/libogg.a" \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/source"
xcrun clang -fobjc-arc -DYL_VORBIS_ARTIFACT=1 -I"$reference/include" -I"$prefix/include" \
 -I"$framework/YlFFmpegBridge.framework/Headers" -F"$framework" "$script_dir/test_vorbis.m" \
 -L"$prefix/lib" -lavformat -lavcodec -lavutil "$reference/lib/libvorbis.a" "$reference/lib/libogg.a" \
 -framework Foundation -framework CoreMedia -framework YlFFmpegBridge -Wl,-rpath,"$framework" -o "$temporary/artifact"
for implementation in source artifact; do
 for rate in 44100 48000; do
  for channels in 1 2; do
   echo "Vorbis $implementation rate=$rate channels=$channels"
   "$temporary/$implementation" "$temporary/$rate-$channels.mkv"
  done
 done
done
