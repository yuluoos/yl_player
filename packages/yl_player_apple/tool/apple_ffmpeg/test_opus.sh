#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
fixture_ffmpeg=${YL_FIXTURE_FFMPEG:-/opt/homebrew/bin/ffmpeg}
YL_OPUS_FRAMEWORK_DIR=${YL_OPUS_FRAMEWORK_DIR:-"$script_dir/../../darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-opus.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
for mode in 2.5 5 10 20 40 60 120 speech silk10 silk20 silk40 narrow medium hybrid hybrid10 gain; do
 for channels in 1 2; do
  duration=$mode
  case "$mode" in
    speech) duration=60; set -- -application voip -b:a 16000 -cutoff 8000 ;;
    silk10|silk20|silk40) duration=${mode#silk}; set -- -application voip -b:a 16000 -cutoff 8000 ;;
    narrow) duration=20; set -- -application voip -b:a 12000 -cutoff 4000 ;;
    medium) duration=20; set -- -application voip -b:a 14000 -cutoff 6000 ;;
    hybrid) duration=20; set -- -application voip -b:a 24000 -cutoff 20000 ;;
    hybrid10) duration=10; set -- -application voip -b:a 24000 -cutoff 20000 ;;
    gain) duration=20; set -- ;;
    *) set -- ;;
  esac
  "$fixture_ffmpeg" -hide_banner -loglevel error -f lavfi \
    -i 'aevalsrc=0.04*sin(2*PI*(440+220*floor(t))*t)|0.04*sin(2*PI*(495+220*floor(t))*t):s=48000:d=4:c=stereo' \
    -ac "$channels" -c:a libopus -frame_duration "$duration" "$@" -write_crc32 0 "$temporary/$mode-$channels.mkv"
  if [ "$mode" = gain ]; then
    python3 - "$temporary/$mode-$channels.mkv" <<'PYGAIN'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);data=bytearray(p.read_bytes())
assert data.count(b'OpusHead') == 1
pos=data.index(b'OpusHead');data[pos+16:pos+18]=(1536).to_bytes(2,'little',signed=True)
p.write_bytes(data)
PYGAIN
  fi
  "$fixture_ffmpeg" -hide_banner -loglevel error -c:a libopus -i "$temporary/$mode-$channels.mkv" \
    -c:a pcm_f32le -f f32le "$temporary/$mode-$channels.pcm"
 done
done
python3 - "$temporary" "$fixture_ffmpeg" <<'PYMANIFEST'
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
print('YL_OPUS_FIXTURES='+json.dumps({
 'generator':subprocess.check_output([sys.argv[2],'-version'],text=True).splitlines()[0],
 'files':{p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size}
          for p in sorted(root.iterdir()) if p.suffix in ('.mkv','.pcm')}
},sort_keys=True))
PYMANIFEST
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_opus.m" -L"$prefix/lib" "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/test_opus"
for mode in 2.5 5 10 20 40 60 120 speech silk10 silk20 silk40 narrow medium hybrid hybrid10 gain; do
 echo "Opus source mode=$mode"
 "$temporary/test_opus" "$temporary/$mode-1.mkv" "$temporary/$mode-1.pcm" "$temporary/$mode-2.mkv" "$temporary/$mode-2.pcm"
done
if [ -n "${YL_OPUS_FRAMEWORK_DIR:-}" ]; then
 xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -DYL_OPUS_ARTIFACT=1 -I"$prefix/include" \
  -I"$YL_OPUS_FRAMEWORK_DIR/YlFFmpegBridge.framework/Headers" -F"$YL_OPUS_FRAMEWORK_DIR" \
  "$script_dir/test_opus.m" -L"$prefix/lib" "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
  -framework Foundation -framework CoreMedia -framework YlFFmpegBridge \
  -Wl,-rpath,"$YL_OPUS_FRAMEWORK_DIR" -o "$temporary/test_opus_artifact"
 for mode in 2.5 5 10 20 40 60 120 speech silk10 silk20 silk40 narrow medium hybrid hybrid10 gain; do
  echo "Opus artifact mode=$mode"
  "$temporary/test_opus_artifact" "$temporary/$mode-1.mkv" "$temporary/$mode-1.pcm" "$temporary/$mode-2.mkv" "$temporary/$mode-2.pcm"
 done
fi
