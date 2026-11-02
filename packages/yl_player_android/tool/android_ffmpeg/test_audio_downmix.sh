#!/bin/bash
set -euo pipefail

# Use a configured/built FFmpeg source tree matching ffmpeg-9.0.1.lock.
source_root=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_binary=$(mktemp "${TMPDIR:-/tmp}/yl-audio-downmix.XXXXXX")
trap 'rm -f "$test_binary"' EXIT
frameworks=()
if [[ $(uname) == Darwin ]]; then frameworks=(-framework CoreFoundation); fi
"${CXX:-c++}" -std=c++17 -idirafter "$source_root" "$script_dir/test_audio_downmix.cpp" \
  "$source_root/libswresample/libswresample.a" "$source_root/libavutil/libavutil.a" \
  "${frameworks[@]}" -lpthread -lm -o "$test_binary"
"$test_binary"
