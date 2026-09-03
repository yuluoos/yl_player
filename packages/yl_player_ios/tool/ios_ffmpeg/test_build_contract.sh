#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_script="$script_dir/build_xcframework.sh"
contract=$(bash "$build_script" --print-contract)

require_line() {
  expected=$1
  if ! printf '%s\n' "$contract" | grep -Fqx -- "$expected"; then
    echo "missing build contract line: $expected" >&2
    exit 1
  fi
}

reject_text() {
  forbidden=$1
  if printf '%s\n' "$contract" | grep -Fq -- "$forbidden"; then
    echo "forbidden build option exposed: $forbidden" >&2
    exit 1
  fi
}

require_line "FFMPEG_VERSION=9.0.1"
require_line "FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
require_line "FFMPEG_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
require_line "FFMPEG_SIGNING_KEY_FINGERPRINT=FCF986EA15E6E293A5644F10B4322F04D67658D8"
require_line "IOS_DEPLOYMENT_TARGET=15.0"
require_line "IOS_ARCHITECTURES=iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64"
require_line "FFMPEG_X86_64_FLAGS=--disable-x86asm"
require_line "--disable-network"
require_line "--disable-programs"
require_line "--disable-avdevice"
require_line "--disable-avfilter"
require_line "--disable-swscale"
require_line "--disable-swresample"
require_line "--enable-demuxer=matroska"
require_line "--enable-protocol=file"
require_line "--disable-gpl"
require_line "--disable-nonfree"

reject_text "--enable-gpl"
reject_text "--enable-nonfree"
reject_text "--enable-decoder=h264"
reject_text "--enable-decoder=hevc"

printf '%s\n' "iOS FFmpeg build contract passed."
