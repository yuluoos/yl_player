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
  python3 "$script_dir/vorbis_delay_fixture.py" "$temporary/$rate-$channels.mkv" "$temporary/$rate-$channels-delay.mkv" "$rate"
 done
done
python3 - "$temporary" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);print('YL_VORBIS_FIXTURES='+json.dumps({p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(root.iterdir())},sort_keys=True))
PY
dav1d="${YL_TEST_DAV1D_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/dav1d-stage/yl_dav1d/install}"
xcrun clang -I"$dav1d/include" -fobjc-arc -I"$reference/include" -I"$opus/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_vorbis.m" -L"$prefix/lib" "$opus/lib/libopus.a" -lavformat -lavcodec -lavutil "$reference/lib/libvorbis.a" "$reference/lib/libogg.a" \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security "$dav1d/lib/libdav1d.a" -o "$temporary/source"
xcrun clang -I"$dav1d/include" -fobjc-arc -DYL_VORBIS_ARTIFACT=1 -I"$reference/include" -I"$prefix/include" \
 -I"$framework/YlFFmpegBridge.framework/Headers" -F"$framework" "$script_dir/test_vorbis.m" \
 -L"$prefix/lib" -lavformat -lavcodec -lavutil "$reference/lib/libvorbis.a" "$reference/lib/libogg.a" \
 -framework Foundation -framework CoreMedia -framework YlFFmpegBridge -Wl,-rpath,"$framework" "$dav1d/lib/libdav1d.a" -o "$temporary/artifact"
xcrun clang -I"$dav1d/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" \
 "$script_dir/test_vorbis_coupling.c" "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a" "$dav1d/lib/libdav1d.a" -o "$temporary/coupling"
"$temporary/coupling"
repo_root=$(CDPATH= cd -- "$script_dir/../../../.." && pwd)
for implementation in ${YL_VORBIS_IMPLEMENTATIONS:-source artifact}; do
 for rate in 44100 48000; do
  for channels in 1 2; do
   echo "Vorbis $implementation rate=$rate channels=$channels"
   "$temporary/$implementation" "$temporary/$rate-$channels.mkv"
   "$temporary/$implementation" "$temporary/$rate-$channels-delay.mkv"
  done
 done
 for fixture in webm-vp9-vorbis.webm mkv-avc-vorbis-codec-delay.mkv; do
  "$temporary/$implementation" "$repo_root/packages/yl_player/example/assets/test_media/format_matrix/$fixture"
 done
done
