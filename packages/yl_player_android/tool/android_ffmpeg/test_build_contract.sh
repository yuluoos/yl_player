#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sh -n "$script_dir/build_shared_libraries.sh"
contract=$(sh "$script_dir/build_shared_libraries.sh" --print-contract)

require_line() {
  printf '%s\n' "$contract" | grep -F -x -- "$1" >/dev/null
}

require_line 'FFMPEG_VERSION=9.0.1'
require_line 'ANDROID_MIN_API=24'
require_line 'ANDROID_NDK_VERSION=28.2.13676358'
require_line 'FFMPEG_SIGNING_KEY_FINGERPRINT=FCF986EA15E6E293A5644F10B4322F04D67658D8'
require_line 'ABIS=arm64-v8a,armeabi-v7a,x86_64'
require_line '--disable-network'
require_line '--disable-gpl'
require_line '--disable-nonfree'
require_line '--disable-encoders'
require_line '--disable-avfilter'
require_line '--enable-demuxer=matroska,flv,mov,mpegts,aac,mp3,ogg'
require_line '--enable-decoder=h264,hevc,aac,mp3,ac3,eac3,dca,flac,opus,vorbis'
require_line '--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc'
require_line '--enable-swresample'
require_line '--enable-pic'
require_line '--enable-static'
require_line '--disable-shared'
require_line 'OUTPUT=one replaceable libyl_player_ffmpeg.so per ABI'
require_line 'BRIDGE=android/src/main/cpp/yl_player_ffmpeg.cpp'

if printf '%s\n' "$contract" | grep -E -- '--enable-(gpl|nonfree|network|encoders|avfilter)' >/dev/null; then
  echo 'unsafe FFmpeg feature enabled' >&2
  exit 1
fi

arm64_flags=$(sh "$script_dir/build_shared_libraries.sh" --print-abi-flags arm64-v8a)
printf '%s\n' "$arm64_flags" | grep -F -x -- '--arch=aarch64' >/dev/null
if printf '%s\n' "$arm64_flags" | grep -F -- '--disable-x86asm' >/dev/null; then
  echo 'arm64 unexpectedly inherited x86-only flags' >&2
  exit 1
fi

x64_flags=$(sh "$script_dir/build_shared_libraries.sh" --print-abi-flags x86_64)
printf '%s\n' "$x64_flags" | grep -F -x -- '--arch=x86_64' >/dev/null
printf '%s\n' "$x64_flags" | grep -F -x -- '--disable-x86asm' >/dev/null

bridge="$script_dir/../../android/src/main/cpp/yl_player_ffmpeg.cpp"
if ! grep -F -- 'glTexSubImage2D' "$bridge" >/dev/null; then
  echo 'software renderer must reuse allocated YUV textures between frames' >&2
  exit 1
fi
