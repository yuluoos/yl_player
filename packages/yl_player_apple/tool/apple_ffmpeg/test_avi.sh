#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${YL_TEST_FFMPEG_BUILD:?Set retained signed FFmpeg build root}"
prefix="$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/stage/yl_ffmpeg/install"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-avi.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -I"${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/include" -I"$prefix/include" -I"$YL_TEST_FFMPEG_BUILD/ffmpeg-9.0.1" \
 -I"$YL_TEST_FFMPEG_BUILD/build/macosx-arm64" -I"$script_dir/../../darwin/native/YlFFmpegBridge/include" \
 "$script_dir/test_avi.m" -L"$prefix/lib" "${YL_TEST_OPUS_PREFIX:-$YL_TEST_FFMPEG_BUILD/build/macosx-arm64/opus-stage/yl_opus/install}/lib/libopus.a" -lavformat -lavcodec -lavutil \
 -framework Foundation -framework CoreMedia -framework CoreVideo -framework Security -o "$temporary/test_avi"
fixture="$script_dir/../../../yl_player/example/assets/test_media/format_matrix/avi-avc-mp3.avi"
python3 - "$fixture" "$temporary/no-index.avi" <<'PYAVI'
import pathlib,struct,sys
b=pathlib.Path(sys.argv[1]).read_bytes();assert b[:4]==b'RIFF' and b[8:12]==b'AVI '
out=bytearray(b[:12]);i=12;removed=0
while i+8<=len(b):
 size=struct.unpack_from('<I',b,i+4)[0];end=i+8+size+(size&1);assert end<=len(b)
 if b[i:i+4]==b'idx1':removed+=1
 else:out.extend(b[i:end])
 i=end
assert removed==1 and i==len(b)
struct.pack_into('<I',out,4,len(out)-8);pathlib.Path(sys.argv[2]).write_bytes(out)
PYAVI
"$temporary/test_avi" "$fixture" "$temporary/no-index.avi"
